# NUC Talos Cluster

This document records the hardware and network facts proven by the manual
installation. The rebuild target is Talos `v1.13.6` with Kubernetes `v1.35.6`;
the `v1.13.2` values below describe the superseded proof of concept and its
rollback media.

## Cluster

| Field | Value |
|---|---|
| Cluster name | nuc-cluster |
| Kubernetes API VIP | 192.168.90.20 |
| Network | 192.168.90.0/24 |
| Gateway | 192.168.90.1 |
| DNS | 192.168.90.2 |
| Manual Talos version | v1.13.2 |
| Rebuild Talos version | v1.13.6 |
| Rebuild Kubernetes version | v1.35.6 |
| Platform | metal |
| Architecture | amd64 |
| Secure Boot | Enabled |
| Bootloader | UEFI only |

## Hardware

| Field | Value |
|---|---|
| Hardware | 3x Intel NUC 11 |
| Install disk | /dev/nvme0n1 |
| Primary NIC interface | enp88s0 |

## Nodes

| Node | IP | Role | Disk | Interface | MAC Address |
|---|---:|---|---|---|---|
| nuc1 | 192.168.90.10 | controlplane | /dev/nvme0n1 | enp88s0 | `<nuc1-mac>` |
| nuc2 | 192.168.90.11 | controlplane | /dev/nvme0n1 | enp88s0 | `<nuc2-mac>` |
| nuc3 | 192.168.90.12 | controlplane | /dev/nvme0n1 | enp88s0 | `<nuc3-mac>` |

MAC addresses are redacted to placeholders. The real values are held out-of-band
and are not published here.

## Image Factory

The Phase 2 rebuild uses one schematic for both Secure Boot artifacts:

| Field | Value |
|---|---|
| Schematic ID | a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79 |
| SecureBoot ISO | https://factory.talos.dev/image/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79/v1.13.6/metal-amd64-secureboot.iso |
| SecureBoot installer image | factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6 |

The values below belong only to the manual `v1.13.2` installation.

| Field | Value |
|---|---|
| Schematic ID | 5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4 |
| SecureBoot ISO | https://factory.talos.dev/image/5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4/v1.13.2/metal-amd64-secureboot.iso |
| SecureBoot installer image | factory.talos.dev/metal-installer-secureboot/5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4:v1.13.2 |

## Extensions

- siderolabs/intel-ucode
- siderolabs/i915
- siderolabs/iscsi-tools
- siderolabs/util-linux-tools

## Secure Boot Notes

Secure Boot keys were enrolled from the Talos SecureBoot USB using:

```text
Enroll Secure Boot keys: auto
```

Secure Boot was verified through the guarded Phase 3 installation workflow and
is recorded in [`phase-3-installation.md`](phases/phase-3-installation.md).

Expected result:

```text
SECUREBOOT   true
```

## Install Boundary

Manual phase:

1. BIOS configuration
2. Secure Boot key enrollment
3. USB boot into Talos maintenance mode
4. Apply per-node Talos machine config
5. Verify NVMe boot, Secure Boot, hostname, services, and partitions

Later automated phases:

1. Render and validate Talos with Talhelper
2. Bootstrap Talos with guarded `talosctl` commands
3. Fetch kubeconfig
4. Bootstrap Flux
5. Let Flux manage Kubernetes resources
