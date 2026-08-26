# Talos Source Boundary

This directory is the declarative source for the NUC Talos cluster. Talhelper inputs
support local generation and validation. A separate guarded workflow installs one node
at a time; it does not bootstrap etcd.

## Source and Generated State

The trackable sources are:

- `talconfig.yaml` for cluster topology, versions, nodes, and patch references
- `talsecret.sops.yaml` for the fully encrypted fresh Talos identity
- `patches/` for reviewed machine configuration fragments

Talhelper renders per-node machine configs into the ignored root
`clusterconfig/` directory. Rendered configs contain credentials and must never
be moved into a trackable path.

## Generation and Validation Workflow

The developer workflow is:

```bash
just repo secrets
just talos generate
just talos validate
just repo validate
```

Generation is local and non-mutating. Applying a rendered config is a separate
guarded operation through `just talos apply <node>` and must not be replaced with
an undocumented raw `talosctl apply-config` command.

`just talos generate` first verifies the loaded repository age identity, then
decrypts the Talos bundle only inside the Talhelper process. It replaces the
ignored `clusterconfig/` output and runs `just talos validate`. Validation checks
all three configs in strict metal mode and asserts the current endpoint, network,
Secure Boot installer, CNI, kube-proxy, encryption, and volume decisions.

`just talos source-validate` is the focused source-only check used internally by
`generate`, `validate`, and `just repo validate`. Developers may run it directly
when changing only trackable Talhelper inputs.

## Installation Workflow

Boot exactly one matching NUC from the approved Talos Secure Boot USB and leave
it in maintenance mode. First run the apply recipe without a confirmation:

```bash
just talos apply nuc1
```

This non-writing pass validates all rendered configs, checks the live Secure
Boot state and exact NVMe identity, rejects unexpected internal disks, and asks
Talos to dry-run the machine config. It then refuses to wipe the disk and prints
the exact confirmation value derived from the live drive serial.

After reviewing the node, path, and serial, rerun with that exact value:

```bash
TALOS_APPLY_CONFIRM='nuc1:/dev/nvme0n1:<live-serial>' \
  just talos apply nuc1
```

The confirmed invocation repeats every guard before it sends the generated
config. Talos then wipes `/dev/nvme0n1`, installs the signed image, and reboots.
Remove the USB during reboot so the internal `Talos Linux UKI` entry starts.
Repeat separately for `nuc2` and `nuc3`; never reuse another node's confirmation
value. The recipe applies machine configuration only and never runs
`talosctl bootstrap`.

If mise is not activated in the shell, prefix either invocation with
`mise exec --`, as described in the root README.

## Live Configuration Workflow

Use `just talos apply-live <node>` only for a machine-configuration change that Talos
accepts in `no-reboot` mode. An unconfirmed invocation validates the generated configs,
confirms the target hostname over the secure Talos API, prints the real no-reboot dry-run
diff, and refuses the write. Review that preview and rerun with the exact target-bound
`TALOS_APPLY_LIVE_CONFIRM` value that the command prints.

The confirmed invocation repeats those checks, applies the config without wiping or
rebooting, and then performs the same secure dry-run again as an independent read-back.
It returns success only when the pinned Talos response reports `Config diff:` followed by
`No changes.`. A failed second dry-run or any remaining diff makes the command fail.

Maintenance-mode `just talos apply <node>` remains a separate destructive installation
workflow. Its complete cluster verification is deferred until all nodes have rebooted
and the bootstrap preflight can check them together.

See the root [`README.md`](../README.md) for workstation setup, the
[platform specification](../docs/specs/010-talos-flux-platform.md) for design rationale,
and the [platform disaster-recovery runbook](../docs/runbooks/platform-disaster-recovery.md)
for reconstruction after workstation or cluster loss.
