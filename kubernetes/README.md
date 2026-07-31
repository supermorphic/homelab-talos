# Kubernetes Source Boundary

This directory holds resources reconciled by Flux. Cilium bootstrap begins in
Phase 5 and the guarded production Flux entrypoint is implemented in Phase 6.

Binding rules for this directory are in [`AGENTS.md`](AGENTS.md); this file is explanatory.

Shared bases and overlays are deferred until the Pi staging cluster creates
actual duplication. The `cluster-apps` Kustomization uses
`deletionPolicy: Orphan` so loss of the root object does not cascade into live
workloads.

## Cilium Bootstrap Boundary

Cilium is the only Kubernetes component installed before Flux because the nodes
cannot become Ready and Flux cannot run without a CNI. Its app-local package is
tracked under `apps/kube-system/cilium/` before it is reconciled by Flux:

```text
cilium/
├── README.md
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── ocirepository.yaml
    ├── helmrelease.yaml
    └── values.yaml
```

`values.yaml` is the single configuration source. `just bootstrap cilium` passes
it to Helm during Phase 5. In Phase 6, the app Kustomization publishes the same
file as a watched ConfigMap and the HelmRelease adopts the existing `cilium`
release in `kube-system`. Cilium begins suspended and protected from pruning;
the guarded adoption recipe records pod UIDs and restarts across the transfer
before staging the permanent Git unsuspend.

All supported Cilium workflows are Just recipes:

| Command | Behavior |
|---|---|
| `just kube cilium-render` | Render the pinned OCI chart to standard output without writing tracked YAML |
| `just kube cilium-validate` | Validate the app package, canonical values, and rendered chart |
| `just kube cilium-status` | Print read-only Helm, node, pod, and Cilium status |
| `just kube cilium-diagnostics` | Print read-only Talos diagnostics from all cluster nodes |
| `just kube cilium-postflight` | Verify test cleanup, Talos diagnostics, and etcd health for routine or post-test checks |
| `just kube cilium-verify` | Run the read-only live Phase 5 acceptance gate |
| `just kube cilium-connectivity-test` | Run and clean up temporary connectivity workloads |
| `just bootstrap cilium` | Guard and install or reconcile the bootstrap Helm release |

Flux workflows are also Just-managed:

| Command | Behavior |
|---|---|
| `just kube flux-validate` | Validate the local Flux graph, SOPS canary, Cilium guards, Kustomizations, and pinned OCI render |
| `just kube flux-preflight` | Check published Git state, live Cilium/Talos/etcd health, and Kubernetes compatibility |
| `just bootstrap flux` | Bootstrap Flux `2.9.2` with a read-only GitHub SSH deploy key |
| `just bootstrap flux-sops` | Install or verify the matching `flux-system/sops-age` identity |
| `just bootstrap flux-ssh-known-hosts` | Preserve the deploy key while repairing GitHub port-443 host trust |
| `just bootstrap flux-adopt-cilium` | Transfer Cilium ownership with guarded workload health and stage the Git unsuspend |
| `just kube flux-status` | Print read-only controllers, sources, Kustomizations, HelmReleases, and pods |
| `just kube flux-verify` | Verify source auth, SOPS, canary, Cilium ownership, Talos, and etcd |
| `just kube flux-canary-test` | Guard deletion and Flux recreation of the noncritical canary Secret |

Phase 7 foundation workflows preserve the same boundary:

| Command | Behavior |
|---|---|
| `just repo pihole-status` | Verify the external Pi-hole HTTPS identity, tracked CA, and application-session write policy |
| `just repo pihole-ca-refresh` | Guard and refresh only the tracked public Pi-hole CA after reinstall or rotation |
| `just repo phase7-secrets` | Validate Cloudflare and Pi-hole credentials and write only SOPS ciphertext |
| `just kube foundation-validate` | Validate the Phase 7 graph, policy, encrypted Secrets, and pinned chart renders |
| `just kube foundation-status` | Print read-only certificate, MetalLB, Gateway, DNS, route, and workload state |
| `just bootstrap foundation` | Guard and reconcile the nine suspended Phase 7 units in dependency order |
| `just kube foundation-verify` | Prove the complete DNS-to-trusted-HTTPS path plus Talos and etcd health |

See [`docs/phase-7-foundation.md`](../docs/phase-7-foundation.md) for credentials,
confirmations, rollout order, failure behavior, and acceptance gates.

SOPS encrypts only Secret `data` and `stringData` fields so metadata remains
reviewable by Flux. Load and validate the repository identity before editing an
encrypted manifest:

```bash
mise exec -- just repo secrets
mise exec -- sops kubernetes/path/to/secret.sops.yaml
mise exec -- just repo verify
```

There is not yet a Just recipe for interactive SOPS editing, so this is an
intentional direct use of a mise-pinned CLI.

Bootstrap and recovery applies are performed through documented guarded `just`
recipes, which invoke the required client internally; they are not direct agent
commands.

See the root [`README.md`](../README.md) for workstation setup and
[`docs/phase-6-flux.md`](../docs/phase-6-flux.md) for the staged bootstrap and
adoption procedure. [`docs/phase-7-foundation.md`](../docs/phase-7-foundation.md)
defines the internal service foundation, and
[`docs/pihole-integration.md`](../docs/pihole-integration.md) covers Pi-hole
reinstall and credential recovery. [`docs/sops.md`](../docs/sops.md) defines the
encryption policy.
