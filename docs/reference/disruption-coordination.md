# Disruption coordination

This reference describes how local node lifecycle, Longhorn resize, bootstrap recovery,
and mutating test workflows coordinate disruption. The lifecycle and recovery rules are
defined in [specification 025](../specs/025-node-lifecycle-and-maintenance.md).

## Lease identities and timing

Node disruption and mutating test orchestration use this Lease:

```text
namespace: flux-system
name: homelab-test-run-lock
leaseDurationSeconds: 90
renew interval: 30 seconds
```

Test-report publication uses a separate Lease:

```text
namespace: flux-system
name: homelab-test-report-publish-lock
```

Publication never acquires, renews, or releases the disruption Lease. Sharing the local
Lease helper does not combine these two coordination domains.

Lease timestamps use Kubernetes `MicroTime`: UTC with exactly six fractional digits,
for example `2026-09-23T12:34:56.000000Z`. A holder identity must match
`[a-zA-Z0-9_.:-]+`. Another valid holder identity is opaque; callers do not infer
authority or operation state from its segments.

## Optimistic ownership operations

Acquisition first reads the Lease. If the object does not exist, the caller creates it.
If it exists without a live foreign holder, the caller replaces it with the observed
`metadata.resourceVersion`. An expired foreign holder can be replaced through the same
optimistic operation. A conflicting replacement must be read again; a fresh foreign
holder blocks the caller and must remain unchanged.

A Lease is live until `renewTime`, or `acquireTime` when `renewTime` is absent, plus
`leaseDurationSeconds`. Missing or invalid time and duration fields are not proof of a
live claim. Callers must still use optimistic replacement and cannot overwrite a newer
object.

Only the current, unexpired holder can pass the ownership check. Only the named holder
can renew or release. Release replaces the Lease with a null `holderIdentity`; it does
not delete the object. A wrong-owner renew or release leaves the stored object unchanged.

The owner renews every 30 seconds while its transaction is active. A renewal error stops
the renewal loop and creates the workflow's failure marker. A workflow checks both the
Lease owner and that marker before consequential mutation. It stops when either check
fails.

A campaign child joins its parent's Lease by verifying the exported parent holder. It
does not acquire the Lease again and never releases the parent's claim. The parent owns
renewal, failure signaling, and final release for the complete campaign.

## Persistent containment takes precedence

The disruption Lease serializes an active transaction. Persistent containment is the
presence of this Kubernetes Node annotation key:

```text
homelab.supermorphic.com/node-lifecycle
```

The local admission helpers refuse whenever any Node contains the key, even when its
value is empty, malformed, or from an unknown schema version. They do not parse or
clear recovery records, restore Longhorn values, or uncordon a Node. A free or expired
Lease never overrides the annotation. The local lifecycle commands own recovery and
remove containment only after recovery is accepted.

The established-node admission helper also requires every Node to be `Ready=True` and
schedulable. Exceptional `bootstrap retry-join` uses the annotation guard without this
readiness requirement because its target can be NotReady after a failed join. Each
workflow repeats the applicable holder and admission checks immediately before
consequential mutation.
