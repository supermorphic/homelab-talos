# NUC Talos Cluster

This document records the current hardware, network, and Talos image inputs. The
declarative source in [`talos/talconfig.yaml`](../../talos/talconfig.yaml) remains
authoritative.

## Cluster

| Field | Value |
|---|---|
| Cluster name | nuc-cluster |
| Kubernetes API VIP | 192.168.90.20 |
| Network | 192.168.90.0/24 |
| Gateway | 192.168.90.1 |
| DNS | 192.168.90.2 |
| Talos version | v1.13.6 |
| Kubernetes version | v1.35.6 |
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

The cluster uses one schematic for both Secure Boot artifacts:

| Field | Value |
|---|---|
| Schematic ID | a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79 |
| SecureBoot ISO | https://factory.talos.dev/image/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79/v1.13.6/metal-amd64-secureboot.iso |
| SecureBoot installer image | factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6 |

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

Secure Boot is part of the guarded Talos installation and validation contract in
[`talos/README.md`](../../talos/README.md).

Expected result:

```text
SECUREBOOT   true
```

## Installation boundary

BIOS configuration, Secure Boot key enrollment, USB boot, and the confirmed machine
configuration apply are operator actions. Talhelper renders ignored machine
configurations from Git. Flux owns Kubernetes desired state after bootstrap. See the
[repository and worktree setup guide](../guides/repository-worktree-setup.md) and
[Talos source boundary](../../talos/README.md).
