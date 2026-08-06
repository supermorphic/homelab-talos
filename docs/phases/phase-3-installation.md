# Phase 3: Replace and Install the NVMes

## Status

- Started: 2026-07-18
- Completed: 2026-07-18
- State: Complete
- Completed nodes: `nuc1`, `nuc2`, `nuc3`
- Etcd bootstrap performed: no

Phase 3 replaces one labeled rollback SSD at a time, boots the matching NUC from
the Talos Secure Boot USB, verifies the live target through the insecure
maintenance API, and applies only that node's generated machine configuration.
No node is bootstrapped until all three installations pass their individual
checks.

## Safety Boundary

The generated configs install to `/dev/nvme0n1` with wipe enabled. The guarded
`just talos apply <node>` recipe therefore:

1. Runs the complete Phase 2 rendered-config validation.
2. Maps only `nuc1`, `nuc2`, and `nuc3` to their documented reserved addresses.
3. Requires the insecure Talos maintenance API to be reachable.
4. Requires Secure Boot to report enabled.
5. Requires one writable, native NVMe target with the exact Samsung 990 PRO 1 TB
   model and capacity.
6. Rejects an unexpected second internal disk and requires the USB boot device
   to remain visible.
7. Runs `talosctl apply-config --dry-run` internally and suppresses the generated
   config diff from terminal output.
8. Requires `TALOS_APPLY_CONFIRM` to contain the node, target path, and live disk
   serial before sending the wipe-enabled config.

The recipe does not bootstrap etcd. The Phase 4 bootstrap workflow remained
disabled until every Phase 3 technical and physical rollback gate passed.

The operator first runs `just talos apply <node>` without the environment
variable. A successful read-only rehearsal ends by printing the exact required
confirmation and refusing the wipe. The operator reviews that value, then reruns
the same recipe with `TALOS_APPLY_CONFIRM` set. Both invocations repeat the full
validation and live-device checks; provisioning does not require a raw
`talosctl apply-config` command.

## Accepted SSD Preflight Deviation

Samsung Magician on macOS could not reach the internal 990 PRO through the
JMicron USB bridge. The operator accepted a waiver for the unavailable firmware
and health scan on 2026-07-18. Direct Talos maintenance-mode inventory remains
mandatory for every node, and an unavailable test is not recorded as a pass.
The original labeled SSDs remain untouched for physical rollback through the
foundation soak gate.

## `nuc1` Pre-Apply Evidence

Collected read-only through the Talos maintenance API on 2026-07-18:

| Check | Observed | Result |
|---|---|---|
| Talos USB version | `v1.13.6`, Linux amd64 | Pass |
| Secure Boot | `true` | Pass |
| Module signature enforcement | `true` | Pass |
| Install target | `/dev/nvme0n1` | Pass |
| Model | `Samsung SSD 990 PRO 1TB` | Pass |
| Capacity | `1,000,204,886,016` bytes | Pass |
| Serial | `<nuc1-nvme-serial>` | Recorded |
| Transport | Native NVMe | Pass |
| Other internal disk | None | Pass |
| Boot media | `/dev/sda`, SanDisk Cruzer Glide, 15 GB USB | Pass |
| Rendered config validation | Strict metal and Phase 2 policy checks | Pass |

Disk serials are redacted to placeholders throughout this document. The real
values are held out-of-band and are not published here.

The successful Secure Boot maintenance boot proves that the existing firmware
trust database accepts the new Sidero Labs Image Factory image. No Secure Boot
key enrollment, clearing, or replacement was performed.

## `nuc2` Pre-Apply Evidence

Collected read-only through the Talos maintenance API on 2026-07-18:

| Check | Observed | Result |
|---|---|---|
| Talos USB version | `v1.13.6`, Linux amd64 | Pass |
| Secure Boot | `true` | Pass |
| Install target | `/dev/nvme0n1` | Pass |
| Model | `Samsung SSD 990 PRO 1TB` | Pass |
| Capacity | `1,000,204,886,016` bytes | Pass |
| Serial | `<nuc2-nvme-serial>` | Recorded |
| Transport | Native NVMe | Pass |
| Other internal disk | None | Pass |
| Talos USB visible | Yes | Pass |
| Rendered config validation | Strict metal and Phase 2 policy checks | Pass |

The unconfirmed Just invocation also completed Talos' machine-config dry run and
refused the disk write before printing the exact live serial-bound confirmation.

## `nuc3` Pre-Apply Evidence

Collected read-only through the Talos maintenance API on 2026-07-18:

| Check | Observed | Result |
|---|---|---|
| Talos USB version | `v1.13.6`, Linux amd64 | Pass |
| Secure Boot | `true` | Pass |
| Install target | `/dev/nvme0n1` | Pass |
| Model | `Samsung SSD 990 PRO 1TB` | Pass |
| Capacity | `1,000,204,886,016` bytes | Pass |
| Serial | `<nuc3-nvme-serial>` | Recorded |
| Transport | Native NVMe | Pass |
| Other internal disk | None | Pass |
| Talos USB visible | Yes | Pass |
| Rendered config validation | Strict metal and Phase 2 policy checks | Pass |

The fail-closed rehearsal completed the machine-config dry run and refused the
disk write before printing nuc3's exact live serial-bound confirmation.

## Installation Progress

| Node | Old SSD labeled and stored | Maintenance checks | Config applied | NVMe boot | Post-install verification |
|---|---|---|---|---|---|
| `nuc1` | Pass | Pass | Pass | Pass | Pass |
| `nuc2` | Pass | Pass | Pass | Pass | Pass |
| `nuc3` | Pass | Pass | Pass | Pass | Pass |

## `nuc1` Apply Evidence

On 2026-07-18, the unconfirmed recipe completed every live guard and Talos
machine-config dry run, then refused the disk write as designed. The confirmed
recipe repeated those checks and Talos accepted `clusterconfig/nuc1.yaml`.

Before the installer rebooted, the authenticated API reported:

- Machine stage `installing`.
- `/dev/nvme0n1` selected as `system-disk`.
- EFI, META, and STATE partitions created on the Samsung NVMe.
- No diagnostic resources reporting an installer error.

The node then dropped its API connection for the installer reboot while remaining
reachable by ICMP at `192.168.90.10`. The operator powered it down, removed the
USB, and cold-booted it from the internal drive. No second apply or forced reboot
was required.

## `nuc1` Post-Install Evidence

Collected through the authenticated Talos API after booting without the USB on
2026-07-18:

| Check | Observed | Result |
|---|---|---|
| Talos API | `v1.13.6`, RBAC enabled | Pass |
| Hostname and address | `nuc1`, `192.168.90.10` | Pass |
| Booted entry | `talos-v1.13.6.efi` | Pass |
| Secure Boot | Enabled; UKI boot and module signatures enforced | Pass |
| Physical disks | Samsung 990 PRO only; USB absent | Pass |
| STATE | 105 MB XFS, LUKS2, TPM slot 0, PCR 7 plus signed PCR 11 | Pass |
| EPHEMERAL | 161 GB XFS, LUKS2, TPM slot 0, locked to STATE | Pass |
| Longhorn | 837 GB XFS at `/var/mnt/longhorn`, unencrypted | Pass |
| Extensions | `intel-ucode`, `i915`, `iscsi-tools`, `util-linux-tools` | Pass |
| Talos diagnostics | None reported | Pass |

Talos reports the machine in its pre-bootstrap boot stage with `etcd not running`
and Kubernetes node readiness unmet. Those conditions are expected until Phase 4
and do not indicate an installation failure. Etcd was not bootstrapped.

## `nuc2` Apply and Post-Install Evidence

On 2026-07-18, the confirmed `just talos apply nuc2` invocation repeated every
guard and Talos accepted `clusterconfig/nuc2.yaml`. The authenticated API then
reported machine stage `installing`, selected `/dev/nvme0n1` as `system-disk`,
and reported no diagnostics before the installer reboot.

After the USB was removed and nuc2 booted from the internal drive, the
authenticated API reported:

| Check | Observed | Result |
|---|---|---|
| Talos API | `v1.13.6`, RBAC enabled | Pass |
| Hostname and address | `nuc2`, `192.168.90.11` | Pass |
| Booted entry | `talos-v1.13.6.efi` | Pass |
| Secure Boot | Enabled; UKI boot and module signatures enforced | Pass |
| Physical disks | Samsung 990 PRO only; USB absent | Pass |
| STATE | 105 MB XFS, LUKS2, TPM slot 0, PCR 7 plus signed PCR 11 | Pass |
| EPHEMERAL | 161 GB XFS, LUKS2, TPM slot 0, locked to STATE | Pass |
| Longhorn | 837 GB XFS at `/var/mnt/longhorn`, unencrypted | Pass |
| Extensions | `intel-ucode`, `i915`, `iscsi-tools`, `util-linux-tools` | Pass |
| Talos diagnostics | None reported | Pass |

As on nuc1, the only unmet machine conditions are etcd and Kubernetes node
readiness. They are expected before Phase 4; etcd was not bootstrapped.

## `nuc3` Apply and Post-Install Evidence

On 2026-07-18, the confirmed `just talos apply nuc3` invocation repeated every
guard and Talos accepted `clusterconfig/nuc3.yaml`. Before reboot, the
authenticated API reported machine stage `installing`, selected
`/dev/nvme0n1` as `system-disk`, and returned no diagnostics.

After the USB was removed and nuc3 booted from the internal drive, the
authenticated API reported:

| Check | Observed | Result |
|---|---|---|
| Talos API | `v1.13.6`, RBAC enabled | Pass |
| Hostname and address | `nuc3`, `192.168.90.12` | Pass |
| Booted entry | `talos-v1.13.6.efi` | Pass |
| Secure Boot | Enabled; UKI boot and module signatures enforced | Pass |
| Physical disks | Samsung 990 PRO only; USB absent | Pass |
| STATE | 105 MB XFS, LUKS2, TPM slot 0, PCR 7 plus signed PCR 11 | Pass |
| EPHEMERAL | 161 GB XFS, LUKS2, TPM slot 0, locked to STATE | Pass |
| Longhorn | 837 GB XFS at `/var/mnt/longhorn`, unencrypted | Pass |
| Extensions | `intel-ucode`, `i915`, `iscsi-tools`, `util-linux-tools` | Pass |
| Talos diagnostics | None reported | Pass |

The only unmet machine conditions are the expected pre-bootstrap etcd and
Kubernetes node readiness checks. Etcd was not bootstrapped.

## Phase 3 Exit Gate

- [x] `nuc1` boots from the internal NVMe without the USB.
- [x] `nuc2` boots from the internal NVMe without the USB.
- [x] `nuc3` boots from the internal NVMe without the USB.
- [x] Every node answers at its reserved address with its expected hostname.
- [x] Secure Boot and expected system extensions are active on every node.
- [x] STATE, EPHEMERAL, and the Longhorn user volume have the expected layout.
- [x] Etcd has not been bootstrapped during Phase 3.
- [x] Each old SSD is labeled with its hostname and removal date and stored
      untouched for rollback.
