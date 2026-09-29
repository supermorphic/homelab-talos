# OpenBao operations

## Mental model and operator actions

The staged OpenBao package defines three Raft voters and short-lived Kubernetes
credential issuance. Git and Flux own its Kubernetes resources. Reviewed
authentication, policy, and issuance configuration is applied through an attended
command. No privileged controller repairs it automatically. Use a clean checkout of
published, deployed `main` for operator workflows.

| Situation | Operator action |
| --- | --- |
| First deployment | Create and retain seal material, prepare the staged servers, initialize once, complete acceptance, then activate through Git. |
| Reviewed OpenBao configuration change or drift | Merge the desired configuration, run the guarded apply command, and verify again. |
| Routine health and configuration check | Run `mise exec -- just kube openbao-verify` with normal scoped observer credentials. |
| Image upgrade | Retain a current recoverable snapshot, publish the reviewed image, then run the attended upgrade. |
| Production recovery | Follow the [platform disaster-recovery boundary](../runbooks/platform-disaster-recovery.md#openbao-credential-broker-state); production Raft or PVC replacement needs explicit operator authorization. |

Offline source validation is `mise exec -- just kube openbao-validate`. It does not
establish live deployment or recovery success.

## Recovery material to retain

Retain these outside this cluster, with access that does not depend on a credential
issued by OpenBao:

- the operator's SOPS age identity and the encrypted Git/off-cluster static seal
  artifact, including older seal generations while their backups are retained;
- the encrypted `openbao-recovery.age` bundle and a private, usable copy of the
  non-root operator login and recovery material;
- off-cluster backup access and each selected Raft snapshot with its recovery record;
- the **matching static seal-key generation** for every retained snapshot that may
  need restoration.

A recovery share or operator password cannot replace a missing matching seal key.
Keep recovery material and credentials out of repository files, command arguments,
logs, and retained test evidence.

## First deployment

### 1. Create seal material

Choose an existing operator-owned `0700` recovery directory outside worktrees and test
output. Load the operator age identity through the repository's normal private
procedure. Set `OPENBAO_RECOVERY_DIRECTORY` and
`OPENBAO_SECRETS_CONFIRM=write:openbao:openbao-seal:sops`, then run:

```sh
mise exec -- just repo openbao-secrets
```

The command creates the encrypted Git Secret and an independent encrypted recovery
copy. Add `./openbao-seal.sops.yaml` to the OpenBao app Kustomization and publish the
encrypted artifact through review. Never regenerate a seal key to repair an existing
installation. Use a different empty recovery directory for initialization.

### 2. Prepare the staged servers

Use this step only for a new installation with all OpenBao Flux units suspended in
Git. For an interrupted initialization with a retained recovery bundle, continue at
step 4. Do not prepare or initialize an existing installation again.

Set `OPENBAO_OPERATOR_KUBECONFIG` to the absolute path of the operator kubeconfig,
`OPENBAO_RECOVERY_RECIPIENT` to the public recipient in the seal artifact, and
`OPENBAO_RECOVERY_DIRECTORY` to the initialization recovery directory. Run:

```sh
mise exec -- just bootstrap openbao prepare
```

Review the reported target, set `OPENBAO_BOOTSTRAP_CONFIRM` to the exact reported
confirmation, and rerun the command. A `prepared` result means the staged servers
are ready for initialization.

### 3. Initialize exactly once

Run `mise exec -- just bootstrap openbao initialize` without confirmation. Review the
reported target, set `OPENBAO_BOOTSTRAP_CONFIRM` to the exact reported confirmation,
and rerun it. Success establishes initialized servers and working operator access.
A lost response or timeout is ambiguous; preserve the servers, claims, and recovery
bundle and investigate. Never retry initialization as a repair step.

### 4. Retain credentials

Confirm that `openbao-recovery.age` was retained independently. Privately import the
non-root operator login and recovery material into the operator's recovery system.
The bootstrap verifies the operator login and revokes the initial root token before
reporting success. Do not depend on that root token for routine administration.

If initialization retained the bundle but stopped during configuration, first run
`mise exec -- just kube openbao-config-apply` as described below. Then complete bootstrap:

```sh
mise exec -- just bootstrap openbao finalize
```

Keep `OPENBAO_OPERATOR_KUBECONFIG` and the public `OPENBAO_RECOVERY_RECIPIENT` set.
Enter the bundle's retained root token at the token prompt. Review and enter the
exact confirmation, then enter the retained operator password at its private prompt.
Success establishes working configuration and operator access, with the initial root
token retired. A successful normal initialization already completes this step.

If configuration is installed but a reviewed server correction must be loaded before
integrations are active, merge it and wait for Flux. Run
`mise exec -- just bootstrap openbao restart-staged` with the same operator kubeconfig,
public recipient, and retained root token; review its exact confirmation. This is
attended and disruptive. Success establishes healthy servers with working configuration
and audit logging. Then run `finalize`.

### 5. Run attended acceptance

Use the explicit operator kubeconfig for `OPENBAO_OPERATOR_KUBECONFIG` and
`TEST_KUBECONFIG`. The server, acceptance, and backup units must be reconciled before
these tests; keep private access and monitoring staged. Each registered test asks for
its own exact execution confirmation and requires operator authority.

| Acceptance | Command and additional input | Passing result establishes |
| --- | --- | --- |
| Issuance | `mise exec -- just test record test.openbao-issuance`; also supply `OPENBAO_DIAGNOSTIC_KUBECONFIG` for the actual scoped diagnostic identity. | Restricted issuance and access-denial behavior work with the intended identities. This is attended and creates temporary test resources. |
| HA | `mise exec -- just test record test.openbao-ha`; provide an authorized OpenBao token at its private prompt. | Voters recover and issuance continues through attended, disruptive member replacement. |
| Restore | `mise exec -- just test record test.openbao-restore-drill`; provide the selected snapshot, matching recovery record and seal material, and operator password as below. | The selected backup restores in isolation and passes recovery checks. It does not perform production recovery. |

**Restore inputs and timing:**

Run the restore drill after a material snapshot, seal-generation, or recovery-workflow
change, and before accepting a selected backup as recoverable. Production OpenBao must
be healthy for the isolation checks. Select `raft.snap` with
its sibling `metadata.json` in operator-private storage. Match the recovery record's
seal ID and generation to retained seal material. From clean deployed `main`, set the
non-secret selectors and run:

```sh
export OPENBAO_OPERATOR_KUBECONFIG='/absolute/private/operator-kubeconfig'
export TEST_KUBECONFIG="$OPENBAO_OPERATOR_KUBECONFIG"
export OPENBAO_RESTORE_SNAPSHOT='/absolute/private/snapshot/raft.snap'
export OPENBAO_RESTORE_SEAL_ID='<seal-id-from-recovery-record>'
export OPENBAO_RESTORE_GENERATION='<generation-from-recovery-record>'
mise exec -- just test record test.openbao-restore-drill
```

Review the exact confirmation shown by the command. Supply matching seal material and
the operator password only through its private prompts. Require both restore and
cleanup to pass. The drill uses isolated scratch resources; a production outage or
production storage replacement needs a separate recovery plan.

### 6. Activate through Git

After acceptance, review and merge the private route, monitoring, and Gatus enrollment
changes. Run the observer verifier after
reconciliation. Activation is complete only when acceptance and live verification pass.

## Apply configuration changes

Merge reviewed changes to the desired configuration and policy files. After the
published source reaches Flux, set `OPENBAO_OPERATOR_KUBECONFIG` to the explicit
operator kubeconfig and `OPENBAO_RECOVERY_RECIPIENT` to the public recipient in the
seal artifact. For an established cluster, run:

```sh
OPENBAO_CONFIG_AUTH=userpass mise exec -- just kube openbao-config-apply
```

Enter the retained `openbao-operator` password at the private prompt. The command
checks the operator policy and revokes its temporary login token when it ends. Review
the sanitized change plan, then enter the exact reported confirmation in the same
terminal session. During incomplete bootstrap repair, omit `OPENBAO_CONFIG_AUTH` and
enter the retained **root token** at its private prompt. If the operator account is
missing, a separate private prompt requests its retained password.
A changed source or live target requires a new review. Success means the installed
configuration matches the reviewed source. Run `openbao-verify` once fresh observations
are available. If apply fails, stop and inspect; do not patch live state by hand.

For `audit-unavailable`, correct and load the reviewed server configuration before
applying API changes. During staged bootstrap, use the restart procedure in step 4.

Leave `OPENBAO_CONFIG_CONFIRM` (or `OPENBAO_BOOTSTRAP_CONFIRM` for finalize/restart) unset
for interactive review. Setting it explicitly to an empty value gives a read-only
preview; setting the exact reported value supports a separately reviewed invocation.

## Normal verification

Run `mise exec -- just kube openbao-verify` with the normal task-scoped observer
credential. It checks live Kubernetes state and fresh, sanitized OpenBao configuration
observations against the deployed source revision. Missing, stale, inaccessible, or
drifted observations fail verification. The check makes no configuration changes.
Investigate a failure and use the attended apply workflow for reviewed repairs.

## Upgrade

Review upstream compatibility and repository version constraints. Retain a verified
snapshot from the running version before publishing the reviewed Git image update.
Select its encrypted archive with `OPENBAO_UPGRADE_SNAPSHOT`; its recovery record must
match the running version and seal generation and be no older than one hour. Select the
explicit operator kubeconfig, then run:

```sh
mise exec -- just kube openbao-upgrade
```

The command prompts privately for an authorized OpenBao token and exact confirmation.
This is attended and disruptive. Success establishes healthy voters on the reviewed
version with working issuance. Run `openbao-verify` afterward. If the upgrade stops
partway through, preserve the snapshot and cluster state for recovery review; do not
improvise a rollback.

## Failure and stop boundaries

- For an established cluster, stop if seal material, the matching generation,
  backup access, or operator recovery material is missing. Do not substitute
  an OpenBao-issued credential for a recovery root.
- Treat an ambiguous initialization result as initialized until inspected. Do not
  retry, manually uninstall or delete claims, or regenerate the seal key.
- If an unused staged initialization has no retained recovery bundle, use the
  attended `mise exec -- just bootstrap openbao-reset-staged` workflow only
  after explicitly authorizing replacement of that staged Raft state. Supply
  the same explicit operator kubeconfig, empty initialization recovery directory,
  public recovery recipient, and the reported `OPENBAO_RESET_CONFIRM` value.
  Keep all OpenBao Flux units suspended. Only after reset succeeds, run `prepare`
  and `initialize` again from clean deployed `main`.
- Do not activate or call recovery complete while issuance, HA, restore, cleanup, or
  observer verification is failing.
- A restore drill proves only its selected isolated backup. Production PVC/Raft
  replacement or force restore requires explicit operator authorization.

## Implementation references

- [Spec 030](../specs/030-openbao-kubernetes-credential-broker.md) owns design,
  security, recovery, and detailed acceptance contracts.
- The [OpenBao package README](../../kubernetes/apps/security/openbao/README.md)
  summarizes the staged source and Flux units.
- [Desired API configuration](../../kubernetes/apps/security/openbao/config/desired.json)
  and its policy files supply reviewed changes. The
  [operator workflow](../../scripts/openbao/operator.py),
  [upgrade script](../../scripts/operations/openbao-upgrade.sh), and
  [acceptance scenarios](../../scripts/test/scenarios/openbao_issuance.py) own guarded
  execution and detailed assertions.
