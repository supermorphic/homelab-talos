# OpenBao operator operations

OpenBao bootstrap and configuration changes are attended operator workflows. Run them
through the pinned toolchain from a clean checkout of published, deployed `main`.
The package remains staged until its operator inputs and live acceptance are complete.
See the [design](../specs/030-openbao-kubernetes-credential-broker.md) and
[package README](../../kubernetes/apps/security/openbao/README.md).

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
servers; it never calls the initialization API.

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
