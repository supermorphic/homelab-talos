# Talos source contract

This directory defines the three Talos nodes. `talconfig.yaml` owns topology,
versions, and patch references; `patches/` holds reviewed machine changes;
`talsecret.sops.yaml` is the encrypted cluster identity. Talhelper renders
credential-bearing machine configs into ignored `clusterconfig/`. Never edit or
commit those rendered files.

## Generate and validate

Use the operator's age identity through the [SOPS guide](../docs/guides/sops-secret-operations.md).
`mise exec -- just talos generate` renders the ignored configs and validates them.
`mise exec -- just talos source-validate` checks only trackable Talhelper inputs.
Generation and validation do not apply a config to a node.

## Install or change a node

`mise exec -- just talos apply <node>` is the guarded **installation** workflow
for one matching NUC booted from the approved Secure Boot USB in maintenance
mode. Run it first without confirmation. It checks the live node and disk,
performs a dry-run, and prints a confirmation bound to that target and its live
drive serial. Review the target before rerunning with the exact
`TALOS_APPLY_CONFIRM` value. The confirmed run repeats the safety checks, writes
the machine config, wipes the installation disk, and reboots. Install one node
at a time; this command does not bootstrap etcd. Do not substitute a raw
`talosctl apply-config` call.

For an established node, use `mise exec -- just talos apply-live <node>` only for
a reviewed change Talos accepts without reboot. Its unconfirmed invocation
shows a no-reboot dry-run; the confirmed invocation repeats checks, applies the
change, and requires a clean read-back. Established-node reboot and maintenance
use the separate `just node` workflows, which coordinate disruption and
Longhorn state. Do not reuse the installation command or manually uncordon an
unaccepted node.

The [platform specification](../docs/specs/010-talos-flux-platform.md) explains
the Talos and Flux design. The [NUC cluster reference](../docs/reference/nuc-cluster.md)
records current hardware and network inputs. Follow the
[platform disaster-recovery runbook](../docs/runbooks/platform-disaster-recovery.md)
for workstation or cluster loss.
