# Recover OpenBao

Recover the platform foundations first: operator SOPS/Talos recovery, Kubernetes,
Cilium, Flux and Longhorn. Retain the operator age identity, encrypted static seal
copy, OpenBao operator login and recovery share, and backup access independently
of OpenBao. See [platform recovery](platform-disaster-recovery.md) and the
[OpenBao operations guide](../guides/openbao-operations.md).

A snapshot needs the matching static seal key. Recovery shares cannot decrypt a
snapshot without that key. Preserve each key generation while its backups remain
retained. Never initialize production storage to make an existing backup readable.

## Attended isolated drill

`mise exec -- just kube openbao-restore-drill` is an operator-owned, registered
mutation test. Live execution requires separate operator authorization. Run it
from the operator-controlled primary checkout with explicitly selected credentials
that can create and inspect the scratch namespace and its resources, execute the
fixed helper routine, and delete the owned resources. It also needs read access to
production API/peer endpoint metadata and cluster role bindings. The workflow does
not select or elevate a worktree identity. The test coordinator needs its ordinary
Lease and disruption-admission access through that same selected identity.
The drill requires a healthy Kubernetes API and three Ready production OpenBao
peers as availability controls for its negative network probes. Run it for backup
assurance while those controls are available. If production peers are already
unavailable, stop for a separately reviewed recovery plan; this command cannot
prove the same peer-isolation acceptance in that state.

1. Retrieve a selected retained snapshot through the backup recovery path into an
   operator-private directory outside repository and evidence directories. Keep
   its sibling `metadata.json` and `raft.snap` together. Use canonical absolute
   paths with no symlink components. Do not select a production PVC for the drill.
2. Check the independently retained recovery record for the snapshot's seal key ID
   and recovery generation. Retrieve and decrypt that matching recovery material
   through the operator's separate private procedure. The runner does not invoke
   age/SOPS, read the age identity, or read any production Secret.
3. Select the non-secret inputs and explicit operator kubeconfig:

   ```bash
   export OPENBAO_OPERATOR_KUBECONFIG='/absolute/operator/kubeconfig'
   export TEST_KUBECONFIG="$OPENBAO_OPERATOR_KUBECONFIG"
   export OPENBAO_RESTORE_SNAPSHOT='/absolute/private/snapshot/raft.snap'
   export OPENBAO_RESTORE_SEAL_ID='openbao-static-seal-v1'
   export OPENBAO_RESTORE_GENERATION='1'
   mise exec -- just test record test.openbao-restore-drill
   ```

   Values above are placeholders except the initial source-defined seal ID and
   generation. Use the selected recovery record, including an older generation
   when that snapshot requires it. Ordinary iteration can use the `kube` recipe;
   intentional recovery assurance uses `test record` for canonical retained evidence.
4. The workflow validates checksum, application version, Raft index, metadata and
   archive structure before it asks for private material. It prints the exact
   `restore:openbao:<sha256>:<canonical-run-id>` confirmation on the controlling
   terminal. Enter that value, the matching seal key encoded as base64, and the
   retained OpenBao operator password at the hidden prompts. There is no echoing
   stdin fallback. Do not put private values in shell arguments, environment
   variables, command history or evidence. `OPENBAO_RESTORE_CONFIRM` can supply the
   same exact confirmation when a coordinator has already established its run ID.
5. Review both the scenario and cleanup results. A passing scenario requires
   scratch initialization once, authenticated snapshot force restore, retained
   operator login, actual restored configuration reads, a healthy single-member
   Raft state, automatic unseal and a second process restart. The source-owned
   acceptance issuance role and ACL serve as the non-secret configuration canary.
   All desired configuration must match the current source; an older incompatible
   snapshot fails acceptance instead of silently accepting historical policy.

Only reviewed server version `2.7.0` is currently accepted, with the source-pinned
image digest. Add compatibility and restore evidence before accepting another
snapshot version.

## Isolation and cleanup

The namespace is unique to the canonical run ID. The workflow creates and reads
back a namespace-wide Cilium deny policy before any Pod. Explicit ingress and
egress denies also override additive allow policies. OpenBao binds only to
loopback. The helper runs in the same Pod and accesses that listener through the
explicitly selected operator's Kubernetes exec channel. No network ingress
exception, route, API token, production binding or production claim is installed.
The helper has no seal or data mount. Only the server mounts the temporary seal
Secret and fresh Longhorn claim.

Before initialization and immediately before restore, the helper checks that its
local listener works and TCP connections to the production API Service/backend
addresses and all three Ready OpenBao peers time out. Refused connections,
unknown endpoints and probe errors fail the gate. After restore and restart,
the drill also makes an authenticated request to the restored production issuance
role and requires backend failure. A login rejection or an absent role cannot
stand in for this negative test. These runtime checks supplement the policy and
resource checks; policy presence alone is insufficient.

The force endpoint follows the [OpenBao Raft snapshot procedure](https://openbao.org/docs/commands/operator/raft/).
It is reachable only through the checked scratch Pod's loopback helper. Fresh
namespace, policy, PVC, workload and Pod identities are checked before the write.
The workflow never retries initialization or force restore after an ambiguous
response. Scratch bootstrap credentials are discarded after restore; matching
retained operator credentials authorize subsequent reads.

Cleanup checks all discoverable namespace resource kinds and stops on unrelated
objects or changed ownership. It uses UID and resource-version preconditions for
Pod and namespace deletion, then waits for namespace removal. A changed marker
or failed deletion produces a separate failed cleanup result. Preserve the
isolated namespace and use an attended, separately reviewed cleanup if that
happens. Do not remove ownership guards or use an unscoped namespace deletion.
Retained evidence contains fixed phases and outcomes, never credentials, snapshot
contents or operator-local file paths.

## Production recovery boundary

The drill never restores a production Pod or claim. A passing isolated drill is a
prerequisite for a separately reviewed production recovery plan. Stop before
production storage replacement, force restore, peer reconfiguration or credential
rotation. Reconcile persistent recovery changes through Git, verify OpenBao, and
only then resume credential consumers. No live restore or recovery-time claim is
established by the local unit tests.
