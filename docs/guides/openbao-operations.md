# OpenBao operator operations

OpenBao bootstrap and configuration changes are attended operator workflows. Run them
through the pinned toolchain from a clean checkout of published, deployed `main`.
The package remains staged until its operator inputs and live acceptance are complete.
See the [design](../specs/030-openbao-kubernetes-credential-broker.md) and
[package README](../../kubernetes/apps/security/openbao/README.md).

Offline validation is `mise exec -- just kube openbao-validate`. The catalog's
`validation.openbao` also runs in core CI. `verification.openbao` is diagnostic
observation, registered but excluded from verification campaigns while any of the
six OpenBao Flux units remains suspended, the encrypted seal artifact is absent
from the app Kustomization, or the Gatus endpoint is not enrolled. It reports
staged absence as a failure,
not deployment acceptance. The three mutating suites remain standalone and require
intentional operator-run `test record` commands. No live bootstrap, issuance,
failover, upgrade, snapshot transfer, or restore result
is recorded by this source package.

Git and Flux own the Kubernetes resources. The reviewed OpenBao API inventory is
in `config/desired.json` and `config/policies/`; a clean deployed `main` revision
is the input for attended `openbao-config-apply`. Flux does not write these API
objects. The verifier reads actual OpenBao configuration with a short-lived
`openbao-config-reader` JWT through the `homelab-diagnostic` Kubernetes context
and compares it with that source. Failed reads and changed reader authority
produce inaccessible or drift results, never a clean result. The operator password
is private recovery material and has no readable drift comparison.

The SOPS Git Secret and off-cluster recovery copy are encrypted. Flux decrypts the
Git artifact into a live Kubernetes Secret; authorized Secret reads and the mounted
seal file expose usable key bytes. The Talos source defines Secretbox encryption
for Kubernetes Secrets, and read-only inspection found all three API servers using
Talos's encryption-provider config. That evidence does not prove every historical
etcd record was rewritten or that authorized live Secret reads are encrypted. The
Talos `STATE` and `EPHEMERAL` volumes were observed as LUKS2; the separate
Longhorn OpenBao data and backup volumes are outside that node-volume boundary.
Keep the operator age identity, encrypted recovery artifacts, and password-manager
copy of the non-root operator login off-cluster. Never depend on a credential
issued by OpenBao to recover OpenBao.

## Create and retain seal material

Select a new absolute recovery directory outside every repository worktree and test
output directory. It must already exist, belong to the operator, and have mode `0700`.
Use a resolved path without symlink components. Retain its contents independently of
the cluster. Use a different empty directory for initialization recovery.

Load the operator age identity by the existing repository procedure. Set
`OPENBAO_RECOVERY_DIRECTORY` and confirm
`OPENBAO_SECRETS_CONFIRM=write:openbao:openbao-seal:sops`, then run:

```sh
mise exec -- just repo openbao-secrets
```

This command invokes `just repo secrets` to validate the selected identity. It generates
32 random seal bytes in memory, encrypts the Kubernetes Secret with SOPS, and retains
an age-encrypted recovery copy before installing the Secret. It refuses any existing
seal artifact. It never regenerates or rotates a seal key as a repair action.

Add `./openbao-seal.sops.yaml` to the app's `kustomization.yaml`, review the encrypted
artifact, and publish it through the normal pull request workflow. Do not decrypt or
paste its value into the shell. Preserve the encrypted recovery copy if installation
or publication fails. Existing ciphertext needs attended inspection, not regeneration.
The operator age private key must remain available independently of this cluster.

## Prepare the staged servers

Explicitly select the operator kubeconfig using `OPENBAO_OPERATOR_KUBECONFIG` with an
absolute path. Ambient `KUBECONFIG` and task diagnostic credentials are not adopted.
Set `OPENBAO_RECOVERY_RECIPIENT` to the public recipient in the encrypted seal artifact.
Set `OPENBAO_RECOVERY_DIRECTORY` to the separate initialization recovery directory.

Run without confirmation to observe the target and obtain the required token:

```sh
mise exec -- just bootstrap openbao prepare
```

Review and set `OPENBAO_BOOTSTRAP_CONFIRM` to the reported value:
`prepare:openbao:<main-sha>:<package-digest>`. Run the same command again.
Preparation uses the existing disruption Lease, temporarily resumes only the owned
prerequisite and server Flux units, and suspends those units again after reconciliation.
It preserves the installed resources. The private route and acceptance units stay
staged until durable activation through Git. Preparation verifies three uninitialized
servers and reports the observed cluster, namespace, workload, Pod, and claim
identities for local review; it never calls the initialization API. Do not copy
these live identifiers into public artifacts.

## Initialize exactly once

Run `mise exec -- just bootstrap openbao initialize` without confirmation. Review the
reported token and set `OPENBAO_BOOTSTRAP_CONFIRM` to
`initialize:openbao:<main-sha>:<target-digest>`, then repeat the command.
The target digest binds cluster, namespace, workload, Pod and claim identities,
configuration, seal key ID, source and public recovery recipient. Any target change
requires new observation and confirmation.

The workflow verifies TLS through loopback-only tunnels to named Pods. It checks all
three initialization states again, sends one initialization request to `openbao-0`,
and immediately retains `openbao-recovery.age` with exclusive creation and durable
flush. That encrypted bundle contains the recovery share, initial root token, and
the new operator password. No plaintext intermediary or credential output is written.

After the three voters join, the workflow installs reviewed authentication, policies
and issuance roles, plus the fixed hashed audit device. It independently reads back
configuration. It verifies a separate `openbao-operator` login before revoking the
initial root token and proving that token is rejected. It revokes its temporary
operator session before success. Import the operator password into the operator's
password manager using an attended, private recovery process.

Do not activate the remaining Flux units until acceptance succeeds. Commit durable
suspension changes and associated monitoring/backup activation through Git.

## Partial success and recovery

A timeout or lost initialization response is ambiguous. Stop, preserve all Pods and
claims, and inspect through the attended recovery procedure. There is no initialization
retry, peer fallback, uninstall, rollback, or PVC deletion. Every rerun refuses any
initialized member, including after a later configuration failure.

If encrypted retention fails after initialization, do not retry initialization. Preserve
any ciphertext already installed; a directory flush failure can leave a valid file with
uncertain durability. If peer joining, configuration, login or root revocation fails,
retain the encrypted bundle and use its operator or recovery material for attended
repair. A failed root revocation is an incomplete result. The workflow never reports
successful bootstrap in that state.

## Apply reviewed configuration

Merge reviewed changes to `config/desired.json` and its policy files, let the Flux source
reach that revision, and use the same explicit kubeconfig and public recipient:

```sh
mise exec -- just kube openbao-config-apply
```

Enter an existing authorized OpenBao token at the hidden terminal prompt. The command
reports a sanitized exact change plan and
`config-apply:openbao:<main-sha>:<target-and-plan-digest>`. Set `OPENBAO_CONFIG_CONFIRM`
to that value and rerun. Changed source, target or live configuration invalidates it.
The command refuses unowned objects, unexpected fields, backend type replacement and
implicit creation of a missing operator password. For a missing operator account, the
confirmed invocation requires the password already retained in the encrypted recovery
bundle at a hidden terminal prompt. It does not generate a new password or change an
existing one. It never deletes objects. After
writes, it reads actual API state with the shared configuration comparator.

Audit is a fixed Git-owned `homelab/` file device targeting stdout, with `log_raw=false`
and `hmac_accessor=true`. Its sanitized read-back is verified separately from the
configuration inventory. Container log retention remains owned by the cluster logging
configuration. Ordinary `openbao-verify` remains observational.

These commands have offline synthetic tests. Live bootstrap, tunnel behavior, retention
on operator storage, and root revocation require attended acceptance; source tests alone
do not establish deployment success.

## Issuance and HA acceptance

These catalog tests are attended and use the explicitly selected
`OPENBAO_OPERATOR_KUBECONFIG`. The catalog records human execution ownership and
holds the existing disruption Lease. The source must be clean, published and
deployed `main`. Activate the acceptance manifests through the reviewed deployment
procedure first. No agent diagnostic credential is upgraded or adopted.

```sh
mise exec -- just test record test.openbao-issuance
mise exec -- just test record test.openbao-ha
```

Set `TEST_KUBECONFIG` to the same explicit operator kubeconfig when invoking the
record command. The convenience wrappers are `just kube openbao-issuance-test`
and `just kube openbao-ha-test`. Each prompts for exact source/target/run
confirmation; this is an execution-intent guard. Operator authority must already
cover creating and cleaning up the bounded test resources and, for HA, evicting
OpenBao members. HA also prompts privately for an authorized OpenBao token to
read Raft state. Tokens never enter command arguments or retained results.

Issuance creates bounded Pods for the exact issuer and acceptance ServiceAccounts.
They mount only projected identity material, with no seal key or server storage.
It makes actual positive and negative TokenRequest calls in the acceptance and
synthetic wrong namespace, and tests empty RBAC/ServiceAccount creation and
synthetic impersonation denial. A timeout, authentication failure, or missing
object cannot stand in for a forbidden response. Unexpected success stops testing;
cleanup checks exact resource ownership and UID/resourceVersion preconditions.

The acceptance workload authenticates to OpenBao, requests a ten-minute reader
credential, checks its audience and effective expiry, asks Kubernetes for its
actual authenticated identity, reads the synthetic canary, and proves a protected
read is forbidden. Before revoking its OpenBao session, it also sends a bounded
request for an unapproved issuance role and requires an ACL denial. Unexpected
success or another response fails acceptance without retaining any returned token.
It revokes the OpenBao session immediately after that check,
while that session is still valid. The Kubernetes checks use the independently
issued JWT. Expiry acceptance polls for authentication rejection with a bound
that includes the API's 60-second leeway, 30 seconds of clock skew, and one
five-second poll. This takes approximately 11 to 12 minutes. The leeway comes from
the pinned [Kubernetes claim validator](https://github.com/kubernetes/kubernetes/blob/v1.35.6/pkg/serviceaccount/claims.go)
and its [JWT validation dependency](https://github.com/kubernetes/kubernetes/blob/v1.35.6/vendor/gopkg.in/go-jose/go-jose.v2/jwt/validation.go).
No OpenBao lease revocation is treated as Kubernetes JWT revocation.

HA evicts one standby, waits for three healthy voters and replicated progress,
then evicts the original leader. Every eviction uses the eviction API and Pod
DisruptionBudget, fresh Pod/owner/leader/quorum observations, and atomic Pod UID
and resourceVersion preconditions. Recovery has a three-minute polling deadline
per replacement; bounded API calls already in flight can finish afterward, but
cannot count as timely recovery. Issuance probes report sampled interruption and recovery duration;
this is not a continuous availability measurement. A failure stops subsequent
mutations and requires attended inspection. Physical power-loss testing remains
in the separately authorized node-lifecycle workflow.

## Upgrade after a Git image update

Review upstream compatibility and the repository version constraints before
publishing the desired image change. `OnDelete` leaves running members in place.
Retain a verified snapshot from the currently running version using the existing
backup procedure. Select its local encrypted archive with
`OPENBAO_UPGRADE_SNAPSHOT`; its sibling `metadata.json` must match the archive,
source seal/recovery generation, and running version, and be no older than one
hour. Do not put credentials or decrypted snapshot contents in the repository.

```sh
mise exec -- just kube openbao-upgrade
```

The command checks the fresh snapshot again before each replacement and verifies
that the deployed StatefulSet template matches the pending Git image and controller
revision. It refuses image downgrades and major-version changes. Compatibility
review remains required; numeric version ordering alone cannot establish it.
It replaces and checks each standby, explicitly requests the old leader to step
down, proves an upgraded voter acquired leadership, then replaces the old leader.
The existing disruption Lease covers the whole sequence. There is no automatic
image or storage rollback. A partial upgrade stops for attended recovery review.

## Isolated renewal and drift interface

`scripts/openbao/maintenance.py` exposes `isolated_renewal` and `isolated_drift`
for an independently provisioned, attended three-voter acceptance environment.
There is deliberately no production command route to these mutation interfaces.
An adapter must bind every request and TLS connection to its recorded namespace
UID, use a namespace named `openbao-isolated-*` owned by the exact run, and expose
fresh namespace ownership and three-voter state on every guard. Provisioning this
live isolated environment and granting its operator/reader authority are separate
prerequisites; the snapshot restore scratch environment does not satisfy them.

Renewal replaces only synthetic TLS material, checks the actual peer certificate
through verified TLS sockets, and requires stable member identities and quorum
through reload. The adapter must return the expected new certificate fingerprint
and use its own isolated trust chain with hostname verification. Drift acceptance
writes and restores a synthetic auth description, acceptance policy, issuance-role
TTL, and reader policy. The isolated reader must observe each configuration change
through the existing comparator and must receive an actual 403 after reader denial.
The observational `openbao-verify` command performs none of these mutations.
Offline fake API and local synthetic TLS tests verify these interfaces; they do
not establish live OpenBao renewal/reload, cluster HA, or RBAC acceptance.

## Activation and follow-up boundary

After attended preparation and initialization, review and commit each durable
Flux unsuspension, private route, backup and monitoring activation, acceptance
resources, and the staged Gatus endpoint through Git. Enroll the verifier in both
verification campaigns only when all six OpenBao Flux units are durably
unsuspended, the encrypted seal artifact is included, and the Gatus endpoint is
enrolled. Run the diagnostic verifier and the separately authorized issuance,
HA, and isolated restore acceptance before calling deployment complete. A passing
offline gate or staged verifier cannot close issue 449. Issue 450 owns real agent
authentication profiles, CLI integration, and replacement of existing worktree
credential installation; this package only proves the dedicated acceptance identity.
