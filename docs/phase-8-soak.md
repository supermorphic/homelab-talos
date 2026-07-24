# Phase 8: Foundation Soak and Recovery

## Status

- Failure tests: complete (2026-07-21)
- Soak window: 2026-07-21 07:22 → 2026-07-22 07:49 MDT (~24h27m) — **passed**
- State: **complete** — all failure tests and the 24-hour soak passed with no
  regressions. The old SSDs are now clear to wipe or reuse; this closes the
  Phases 0–8 foundation milestone.

The cluster runs entirely on the three NUCs (Talos, Kubernetes, Cilium, Flux,
MetalLB, cert-manager, ExternalDNS, echo). The operator workstation only runs
`kubectl`/`talosctl`/`just` on demand, so nothing needs to stay running locally
during the soak.

## Failure Tests (passed 2026-07-21)

All driven through guarded Just recipes, not raw commands.

| Test | Recipe | Result |
|---|---|---|
| Rolling reboot, one node at a time | `just bootstrap reboot nuc1\|nuc2\|nuc3` | Each node rebooted, TPM auto-unlocked STATE and EPHEMERAL (LUKS2), rejoined etcd to three members, and passed `foundation-verify`. |
| MetalLB failover | (during `just bootstrap reboot nuc2`) | `192.168.90.30` was announced from nuc2; when nuc2 rebooted the announcement failed over to another node and returned healthy. |
| Flux controller restart | `just kube flux-restart` | The four flux-system controllers restarted, `flux check` passed, `cluster-apps` reconciled, and `flux-verify` confirmed reconciliation resumed. |
| Application remove/recreate through Git | Git edit of `kubernetes/apps/kustomization.yaml` | Removing `./testing` pruned the echo Kustomization and its workload/namespace; restoring it recreated echo with HTTPS `200`. |

The `just bootstrap reboot <node>` recipe refuses to reboot unless the cluster is
already healthy (three Ready nodes, three etcd members, no alarms), so a rolling
reboot never removes a second node while another is still recovering.

## Soak Baseline (t0: 2026-07-21 07:22 MDT)

Compare against this at the 24-hour mark; the gate passes only if there is no
regression from it.

- Unhealthy pods: 0 (no CrashLoopBackOff, Error, or Pending)
- Container restarts: 7 total, all on nuc1 `kube-controller-manager` (3) and
  `kube-scheduler` (4) as reboot/leader-election artifacts; all other pods 0
- Wildcard certificate: `notAfter 2026-10-18`, `renewalTime 2026-09-18` — no
  renewal occurs inside the soak window
- etcd: three members, ~20 MB each, no errors, no alarms

## Soak Gate Criteria

Run the foundation for at least 24 hours with:

- No etcd alarms or unexpected member changes
- No repeated controller crash loops (restart counts stable versus t0)
- No certificate issuance or renewal errors
- No Pi-hole record churn
- No recurring Cilium connectivity or endpoint regeneration failures
- No TPM unlock or volume mount failures

### Re-verification at the 24-hour mark

```bash
cd /Users/ksiggins/Development/homelab-talos
mise exec -- just kube foundation-verify
mise exec -- kubectl --kubeconfig .kube/config get pods -A --no-headers \
  | awk '{r=$5; sub(/\(.*/,"",r); tot+=r} END{print "total container restarts:", tot+0}'
mise exec -- talosctl --talosconfig .talos/config \
  --nodes 192.168.90.10,192.168.90.11,192.168.90.12 \
  --endpoints 192.168.90.10,192.168.90.11,192.168.90.12 etcd alarm list
```

`foundation-verify` must pass, restarts must not have grown beyond the t0
artifacts, and there must be no etcd alarms. Then set this document's status to
complete and record the outcome below.

## Recorded Evidence

### Versions

| Component | Version |
|---|---|
| Talos | `v1.13.6` (all three nodes) |
| Kubernetes | `v1.35.6` (all three nodes) |
| Flux | `2.9.2` |
| Cilium chart | `cilium-1.19.6` |
| cert-manager chart | `cert-manager-1.21.0` |
| MetalLB chart | `metallb-0.16.1` |
| Envoy Gateway chart | `gateway-helm-1.8.2` |
| ExternalDNS chart | `external-dns-1.21.1` (app `v0.21.0`) |

### Image Factory schematic and extensions

- Installer image:
  `factory.talos.dev/metal-installer-secureboot/a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79:v1.13.6`
- Schematic ID: `a41f967fabc5d1edf3efe2fa2833662218a338b7569216cbfde1d324a4963d79`
- System extensions: `siderolabs/intel-ucode`, `siderolabs/i915`,
  `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools`

### Disk layout and encryption (per node, `/dev/nvme0n1`, Samsung SSD 990 PRO 1TB)

| Volume | Partition | Size | Filesystem | Encryption |
|---|---|---:|---|---|
| STATE | `/dev/nvme0n1p3` | ~105 MB | — | LUKS2, TPM-sealed |
| EPHEMERAL | `/dev/nvme0n1p4` | ~161 GB (150 GiB cap) | — | LUKS2, TPM-sealed |
| `u-longhorn` | `/dev/nvme0n1p5` | ~837 GB | XFS at `/var/mnt/longhorn` | none (unencrypted by design) |

STATE and EPHEMERAL are LUKS2 with TPM-sealed keys bound to a signed PCR policy,
verified to auto-unlock across reboots during the failure tests. The Longhorn
user volume is intentionally unencrypted; its data protection comes from
replication, backups, and application-layer secrets.

### Recovery commands

| Situation | Command |
|---|---|
| Re-render Talos configs from `talconfig.yaml` + `talsecret.sops.yaml` | `just talos generate` (needs `SOPS_AGE_KEY`) |
| Apply a config change to a running node (no wipe) | `just talos apply-live <node>` (`TALOS_APPLY_LIVE_CONFIRM`) |
| Reinstall a node from maintenance mode (wipes) | `just talos apply <node>` (`TALOS_APPLY_CONFIRM`) |
| Reboot a node with a full recovery gate | `just bootstrap reboot <node>` (`TALOS_REBOOT_CONFIRM`) |
| Retry a failed etcd join on nuc2/nuc3 | `just bootstrap retry-join <node>` (`TALOS_ETCD_RETRY_CONFIRM`) |
| Restart the Flux controllers | `just kube flux-restart` (`FLUX_RESTART_CONFIRM`) |
| Full acceptance re-verify | `just kube foundation-verify` |
| Read-only health views | `just bootstrap status`, `just kube foundation-status`, `just kube flux-status` |
| SOPS/age identity recovery | see [`recovery.md`](recovery.md) |

### Support-bundle procedure

Generate a Talos support bundle (writes to the ignored `support-bundles/`
directory; never commit it, as it can contain sensitive runtime data):

```bash
mkdir -p support-bundles
mise exec -- talosctl --talosconfig .talos/config \
  --nodes 192.168.90.10,192.168.90.11,192.168.90.12 \
  --endpoints 192.168.90.10 \
  support --output support-bundles/nuc-cluster-$(date +%Y%m%d).zip
```

## Soak Outcome

**Passed — 2026-07-22 07:49 MDT (~24h27m window).** Re-verification at the gate:

- `just kube foundation-verify` → exit 0; certificates, MetalLB, Envoy Gateway,
  Pi-hole DNS, trusted HTTPS, echo, Cilium, Talos, and etcd all healthy.
- Container restarts: 7 total — unchanged from the t0 baseline (nuc1
  `kube-controller-manager` 3 + `kube-scheduler` 4 reboot artifacts); no new crash
  loops over the full window.
- Unhealthy pods: 0. etcd: three members, no alarms. No certificate renewal was
  due in-window; no Pi-hole record churn.

Phase 8 and the Phases 0–8 foundation milestone are complete. The old SSDs are
now clear to wipe or reuse.
