# Disruption coordination

This reference defines the Kubernetes wire protocol shared by independently maintained
workflows that can make a node or required workload unavailable. It does not define a
shared code package. Each repository owns and tests its own implementation.

Stage A of the issue 431 migration keeps the current local lifecycle commands and the
node abrupt-loss scenario operational. The companion replacement must pass the
acceptance gate in [specification 025](../specs/025-node-lifecycle-and-maintenance.md)
before those entrypoints or their implementation can be retired.

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
`[a-zA-Z0-9_.:-]+`. Implementations treat another valid holder identity as opaque;
they do not infer authority or operation state from its segments.

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

Local admission refuses whenever any Node contains the key. The annotation value can be
empty, malformed, or from an unknown schema version. Local retained workflows do not
parse it, clear it, restore Longhorn values, or uncordon the Node. A free or expired
Lease never overrides the annotation.

Established-node operations also require every Node to be `Ready=True` and schedulable.
Exceptional `bootstrap retry-join` uses only the annotation guard because its target is
expected to have a failed join and can be NotReady. Each workflow repeats the applicable
holder and admission checks immediately before its consequential mutation.

## Recovery record compatibility

The replacement lifecycle implementation must recover the existing schema-version-1
records. These examples use synthetic Node names:

```json
{"schemaVersion":1,"kind":"reboot"}
```

```json
{"schemaVersion":1,"kind":"abrupt-loss"}
```

```json
{
  "schemaVersion": 1,
  "kind": "maintenance",
  "longhorn": {
    "allowScheduling": {"before": true, "during": false},
    "evictionRequested": {"before": false, "during": true}
  }
}
```

For maintenance, recovery restores a value only when its live value still equals the
recorded `during` value. A value already equal to `before` needs no change. Any other
value is an ownership conflict and preserves containment. Final annotation removal and
uncordon occur only after accepted recovery.

The local guards intentionally do not implement this recovery contract. They direct the
operator to the validated playbook recovery interface after that replacement exists.
