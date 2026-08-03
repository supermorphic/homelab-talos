# Phase 0: Preserve and Preflight

## Status

- Started: 2026-07-12
- State: Complete with documented Samsung diagnostic waiver
- Running cluster changes performed: none
- Rollback tag: `manual-talos-v1.13.2`
- Baseline commit: `b338afb14c7fb400486a575c1a6824dd90427744`

This document records the evidence gathered before replacing the NUC system
drives. Do not shut down or open a NUC until the remaining checks are complete and
the Phase 1 and Phase 2 artifacts referenced by the exit gate exist.

## Repository Audit

| Check | Result |
|---|---|
| Generated Talos files ignored | Pass |
| `_out/` ignored | Pass |
| Tracked talosconfig or kubeconfig | None |
| Tracked private-key material | None found |
| Documented `AGE-SECRET-KEY-...` placeholder | Present in `docs/sops.md`; expected |
| Legacy node configs validate for metal mode | Pass for `nuc1`, `nuc2`, and `nuc3` |
| Rollback tag | Created locally at the baseline commit |

The rollback tag contains the committed patches, documentation, encrypted Talos
secret bundle, and platform plan. It does not contain ignored generated machine
configs, talosconfig, kubeconfig, or plaintext age keys. Push the tag after the
new private GitHub remote is created in Phase 6.

## Live Node Inventory

Inventory was collected through the read-only Talos API using the ignored legacy
talosconfig. No config, service, or power operations were sent to the nodes.
The `nuc1` portion was rerun on 2026-07-12 after its reachability was restored;
its legacy machine config was also revalidated locally in metal mode.

| Field | nuc1 | nuc2 | nuc3 |
|---|---|---|---|
| Address | `192.168.90.10` | `192.168.90.11` | `192.168.90.12` |
| Reachability | Reachable | Reachable | Reachable |
| Talos | `v1.13.2` | `v1.13.2` | `v1.13.2` |
| Product | NUC11TNKi5 | NUC11TNKi5 | NUC11TNKi5 |
| System revision | M11922-404 | M11922-404 | M11922-405 |
| System serial | `<nuc1-system-serial>` | `<nuc2-system-serial>` | `<nuc3-system-serial>` |
| Baseline BIOS | TNTGL357.0043 | TNTGL357.0070 | TNTGL357.0067 |
| Baseline BIOS date | 2020-12-23 | 2022-10-28 | 2022-07-18 |
| Secure Boot | Enabled | Enabled | Enabled |
| Boot method | UKI | UKI | UKI |
| Module signatures | Enforced | Enforced | Enforced |
| TPM devices | `/dev/tpm0`, `/dev/tpmrm0` | `/dev/tpm0`, `/dev/tpmrm0` | `/dev/tpm0`, `/dev/tpmrm0` |
| NIC | `enp88s0`, Intel I225-LM | `enp88s0`, Intel I225-LM | `enp88s0`, Intel I225-LM |
| NIC MAC | `<nuc1-mac>` | `<nuc2-mac>` | `<nuc3-mac>` |
| Link | 2.5 Gbps full duplex | 2.5 Gbps full duplex | 2.5 Gbps full duplex |
| Old NVMe | KINGSTON SA2000M8250G, 250 GB | FPI256MWR7, 256 GB | KINGSTON SNVS250G, 250 GB |
| Old NVMe serial | `<nuc1-old-nvme-serial>` | `<nuc2-old-nvme-serial>` | `<nuc3-old-nvme-serial>` |

Hardware serials and MAC addresses are redacted to placeholders throughout this
document. The real values are held out-of-band and are not published here.

`nuc1` reports the full BIOS identifier
`TNTGL357.0043.2020.1223.1022`. All three nodes use Image Factory schematic:

```text
5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4
```

Active legacy extensions are `intel-ucode`, `iscsi-tools`, and
`util-linux-tools`. The new schematic will additionally use the current `i915`
extension and will receive a different content-addressed ID.

## Current Cluster State

- `nuc1` now discovers `nuc2` and `nuc3` as Talos control-plane members; combined
  with the earlier `nuc2` and `nuc3` observation, all three nodes are present in
  discovery.
- Kubelet is running and healthy on all three nodes.
- Etcd is preparing on `nuc1`; the earlier checks found it failed on `nuc2` and
  `nuc3` while waiting to build the initial cluster.
- `talosctl etcd status` returns no member status on `nuc1`.

This confirms that the old environment was installed but never bootstrapped into
a functioning etcd/Kubernetes control plane. There is no etcd state to migrate or
snapshot before rebuilding.

## Network and DHCP Evidence

The live interface and address information matches these documented
reservations:

| MAC | Observed address | Result |
|---|---|---|
| `<nuc1-mac>` | `192.168.90.10/24` | Pass |
| `<nuc2-mac>` | `192.168.90.11/24` | Pass |
| `<nuc3-mac>` | `192.168.90.12/24` | Pass |

On 2026-07-18, the operator directly verified that the router reservation objects
map all three documented MAC addresses to their intended node addresses. The live
leases and persistent reservation definitions now agree.

## BIOS Preflight

ASUS lists BIOS Full Package Update 0080 for the NUC11TNKi5 family, dated
2026-06-26, with security patches, BIOS flash robustness improvements, and
platform fixes. The published package SHA-256 is
`35EE0AAEB2550E057F6E616B366A785799B79056DF3C5ACB11D546DE91B3FBEF`:

https://www.asus.com/us/supportonly/nuc11tnki5/helpdesk_bios/

Required operator actions:

- [x] Power on `nuc1` and record its BIOS version and date.
- [x] Update all three NUCs to BIOS 0080 using the ASUS-supported F7 or UEFI
      method.
- [ ] Keep reliable power connected throughout each firmware update.
- [x] After each update, verify UEFI-only boot, Secure Boot, TPM 2.0, boot order,
      and the NIC settings because firmware updates can reset setup values.
- [x] Boot the old Talos disk once and reconfirm `securitystate.secureBoot: true`
      and the presence of `/dev/tpm0` before replacing the SSD.

Do not enroll the new TPM-backed volume keys until the BIOS updates and firmware
settings are final.

### BIOS Update Evidence

On 2026-07-18, the operator reported that all three NUCs were updated to:

```text
TNTGL357.0080.2026.0514.1751
```

| Node | BIOS version | BIOS build date | Result |
|---|---|---|---|
| `nuc1` | `TNTGL357.0080.2026.0514.1751` | 2026-05-14 | Pass |
| `nuc2` | `TNTGL357.0080.2026.0514.1751` | 2026-05-14 | Pass |
| `nuc3` | `TNTGL357.0080.2026.0514.1751` | 2026-05-14 | Pass |

On 2026-07-18, the operator verified UEFI-only boot, Secure Boot, TPM 2.0/PTT,
USB boot availability, expected boot order, and the enabled NIC with its unchanged
MAC address on every NUC. A read-only Talos API query also reported
`securitystate.secureBoot: true` and enforced module signatures on all three
running legacy installations.

## New Samsung NVMe Preflight

Each new drive remains a physical prerequisite until it is installed and
inventoried directly through that node's Talos maintenance API.

Use the current Samsung Magician release or Samsung's bootable 990 PRO firmware
utility from:

https://semiconductor.samsung.com/consumer-storage/support/tools/

For each drive, verify authenticity, record the values below, run the supported
health/diagnostic test, and apply any firmware Samsung Magician offers for that
exact model and capacity.

| Intended node | Model | Capacity | Serial | Firmware | Health test | Updated |
|---|---|---:|---|---|---|---|
| nuc1 | Samsung SSD 990 PRO 1TB | 1,000,204,886,016 bytes | `<nuc1-nvme-serial>` | Unavailable through USB bridge | Waived; direct Talos inventory passed | Not verified |
| nuc2 | Samsung SSD 990 PRO 1TB | 1,000,204,886,016 bytes | `<nuc2-nvme-serial>` | Unavailable through USB bridge | Waived; direct Talos inventory passed | Not verified |
| nuc3 | Samsung SSD 990 PRO 1TB | 1,000,204,886,016 bytes | `<nuc3-nvme-serial>` | Unavailable through USB bridge | Waived; direct Talos inventory passed | Not verified |

Do not infer the correct firmware solely from a version found online. Samsung
publishes different firmware packages by product variant, and Magician should
validate both drive authenticity and the applicable update.

On 2026-07-18, the operator accepted an explicit waiver for all three drives'
firmware and health tests because the JMicron USB bridge hid the NVMe identity
and rejected SMART/NVMe pass-through. After direct installation, the Talos
`v1.13.6` Secure Boot USB reported the expected native `/dev/nvme0n1`, exact
Samsung model and capacity, serials shown above, and no unexpected second
internal disk. This waiver is not recorded as a health-test pass; the labeled
old SSD remains the rollback mechanism.

## Historical Artifact Validation

During Phase 0, the three historical configs passed `talosctl validate --mode
metal`. Each config installed to `/dev/nvme0n1`, wiped the target, and referenced
the same historical Secure Boot installer:

```text
factory.talos.dev/metal-installer-secureboot/5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4:v1.13.2
```

The matching legacy ISO URL is documented, but no ISO or disk image is stored in
the repository. These configs prove the previous render process only. They must
not be applied to the new drives. The historical repository artifacts and local
generated credentials were retired from the current branch after the new cluster
completed Phase 5.

## Physical Rollback Labels

Label the removed old drives before leaving the workbench:

| Label | Required text |
|---|---|
| nuc1 old SSD | `nuc1 - Talos v1.13.2 - removed YYYY-MM-DD - 192.168.90.10` |
| nuc2 old SSD | `nuc2 - Talos v1.13.2 - removed YYYY-MM-DD - 192.168.90.11` |
| nuc3 old SSD | `nuc3 - Talos v1.13.2 - removed YYYY-MM-DD - 192.168.90.12` |

Store the old drives in separate antistatic containers. Do not attach an old disk
to a NUC after that NUC has joined the fresh cluster unless performing the
documented physical rollback with the machine isolated from the new cluster.

## Remaining Phase 0 Exit Gate

- [x] Repository contains no tracked generated credentials or private key.
- [x] Rollback tag exists locally.
- [x] Historical configs validated successfully before retirement.
- [x] Live inventory recorded for nuc2 and nuc3.
- [x] Live inventory recorded for nuc1.
- [x] Router DHCP reservations verified directly for all three MAC addresses.
- [x] All NUCs updated to BIOS 0080.
- [x] Post-update UEFI-only boot, Secure Boot, TPM 2.0/PTT, USB boot availability,
      expected boot order, and enabled NIC with unchanged MAC address rechecked
      on all three NUCs.
- [x] Old Talos disks booted after the BIOS update; Secure Boot and TPM presence
      were reconfirmed on all three NUCs.
- [x] All three Samsung drives were inventoried directly through Talos; firmware
      and health tests were explicitly waived because the USB bridge did not
      support the required NVMe pass-through.
- [x] Phase 1 repository/tooling work is complete.
- [x] Phase 2 Talhelper configs validate for all three nodes.
- [x] The new ISO and installer share the same Talos version and schematic ID.
- [x] The new Secure Boot USB reaches maintenance mode without applying config or
      modifying a disk.
- [x] All three old SSDs are labeled with hostname and removal date and stored
      untouched for rollback.

Phase 0 closed after the operator checks, explicit drive-diagnostic waiver, and
Phase 1/2 dependencies completed.
