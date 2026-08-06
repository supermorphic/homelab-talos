# Talos Source Boundary

This directory is the declarative source for the NUC Talos cluster. Phase 2
established the Talhelper inputs and enabled local generation and validation.
Phase 3 enables a guarded, one-node-at-a-time installation workflow; it does not
enable etcd bootstrap.

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
just repo verify
```

Generation is local and non-mutating. Applying a rendered config is a separate
Phase 3 operation through `just talos apply <node>` and must not be replaced with
an undocumented raw `talosctl apply-config` command.

`just talos generate` first verifies the loaded repository age identity, then
decrypts the Talos bundle only inside the Talhelper process. It replaces the
ignored `clusterconfig/` output and runs `just talos validate`. Validation checks
all three configs in strict metal mode and asserts the Phase 2 endpoint, network,
Secure Boot installer, CNI, kube-proxy, encryption, and volume decisions.

`just talos source-validate` is the focused source-only check used internally by
`generate`, `validate`, and `just repo verify`. Developers may run it directly
when changing only trackable Talhelper inputs.

## Phase 3 Installation Workflow

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
`mise exec --`, as described in the root README. Record each result in
[`docs/phases/phase-3-installation.md`](../docs/phases/phase-3-installation.md).

See the root [`README.md`](../README.md) for workstation setup and the canonical
[`Talos and Flux platform architecture`](../docs/decisions/2026-08-02-talos-flux-platform.md) for
machine configuration decisions and phase gates.
