# Install Talos on a NUC

## Purpose

Install a rendered Talos machine config on exactly one matching NUC through the
guarded apply workflow. This procedure does not bootstrap etcd.

## Procedure

Boot exactly one matching NUC from the approved Talos Secure Boot USB and leave
it in maintenance mode. First run the apply recipe without a confirmation:

```bash
mise exec -- just talos apply nuc1
```

This non-writing pass validates all rendered configs, verifies the live Secure
Boot state and exact NVMe identity, rejects unexpected internal disks, performs a
Talos dry-run, refuses the wipe, and prints the exact serial-bound confirmation
value.

After reviewing the node, path, and live serial, rerun with that exact value:

```bash
TALOS_APPLY_CONFIRM='nuc1:/dev/nvme0n1:<live-serial>' \
  mise exec -- just talos apply nuc1
```

The confirmed invocation repeats every guard, then installs and reboots exactly
one matching node. Remove the USB during reboot so the internal `Talos Linux UKI`
entry starts. The recipe applies machine configuration only and never runs
`talosctl bootstrap`.

Repeat the procedure independently for `nuc2` and `nuc3`, using the value printed
for that node.

Record the installation evidence in
[`docs/phase-3-installation.md`](../phase-3-installation.md).
