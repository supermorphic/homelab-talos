# Kubernetes Source Boundary

This directory holds resources reconciled by Flux. Cilium is bootstrapped before Flux,
and the guarded production Flux entrypoint then adopts it.

## Layout Rules

- Flux cluster entrypoints belong under `flux/clusters/prod/`.
- Components own their manifests, chart source, Helm configuration, first-party
  configuration, routing, monitoring, and local documentation under
  `apps/<namespace>/<app>/`.
- Each application has an explicit `ks.yaml` entrypoint and an `app/` directory.
  A directory is not deployed merely because it exists; a parent Flux
  Kustomization must include it.
- Shared bases and overlays are deferred until the Pi staging cluster creates
  actual duplication.
- Rendered Helm output is validation material, not declarative source, and remains
  ignored.

Use a `HelmRelease` for infrastructure controllers and applications with a
healthy maintained chart. Use focused native Deployments, Services, HTTPRoutes,
PVCs, and related resources when no trustworthy chart exists. Do not commit the
output of `helm template`, Kompose, or another third-party generator as the
declarative source.

Flux dependencies replace implicit directory ordering and numeric sync waves.
Split controllers from the custom resources that depend on them, then use
`dependsOn`, readiness waiting, and health checks. Examples include cert-manager
before issuers, MetalLB before address-pool resources, Envoy Gateway before
Gateways and HTTPRoutes, and Longhorn before PVC consumers.

The production root at `flux/clusters/prod/apps.yaml` creates the `cluster-apps`
Kustomization. Explicit native Kustomization files under `apps/` select the child
Flux Kustomizations; Flux does not recursively deploy arbitrary directories.
`cluster-apps` uses `deletionPolicy: Orphan` so loss of the root object does not
cascade into live workloads.

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
it to Helm before Flux is available. After Flux bootstrap, the app Kustomization
publishes the same file as a watched ConfigMap and the HelmRelease adopts the existing
`cilium` release in `kube-system`. Cilium begins suspended and protected from pruning;
the guarded adoption recipe records pod UIDs and restarts across the transfer
before staging the permanent Git unsuspend. Do not apply `ks.yaml`,
`ocirepository.yaml`, or `helmrelease.yaml` manually.

All supported Cilium workflows are Just recipes:

| Command | Behavior |
|---|---|
| `just kube cilium-render` | Render the pinned OCI chart to standard output without writing tracked YAML |
| `just kube cilium-validate` | Validate the app package, canonical values, and rendered chart |
| `just kube cilium-status` | Print read-only Helm, node, pod, and Cilium status |
| `just kube cilium-diagnostics` | Print read-only Talos diagnostics from all cluster nodes |
| `just kube cilium-postflight` | Verify test cleanup, Talos diagnostics, and etcd health for routine or post-test checks |
| `just kube cilium-verify` | Run the read-only live Cilium acceptance gate |
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

Foundation workflows preserve the same boundary:

| Command | Behavior |
|---|---|
| `just repo pihole-status` | Verify the external Pi-hole HTTPS identity, tracked CA, and application-session write policy |
| `just repo pihole-ca-refresh` | Guard and refresh only the tracked public Pi-hole CA after reinstall or rotation |
| `just repo foundation-provider-secrets` | Validate Cloudflare and Pi-hole credentials, write only SOPS ciphertext, and update the ExternalDNS rollout stamp |
| `just kube foundation-validate` | Validate the foundation graph, policy, encrypted Secrets, and pinned chart renders |
| `just kube foundation-status` | Print read-only certificate, MetalLB, Gateway, DNS, route, and workload state |
| `just bootstrap foundation` | Guard and reconcile the nine suspended foundation units in dependency order |
| `just kube foundation-verify` | Prove the complete DNS-to-trusted-HTTPS path plus Talos and etcd health |

The Gateway owns one wildcard certificate in `networking`; application routes do
not copy TLS private keys. ExternalDNS publishes only routes carrying
`external-dns.k8s.io/audience=internal`. Use the
[Pi-hole integration guide](../docs/guides/pihole-integration.md) for its external DNS
credential and recovery procedures.

Kubernetes Secret manifests use the `*.sops.yaml` suffix. SOPS encrypts only
their `data` and `stringData` fields so metadata remains reviewable by Flux. Load
and validate the repository identity before editing an encrypted manifest:

```bash
just repo secrets
mise exec -- sops kubernetes/path/to/secret.sops.yaml
just repo verify
```

There is not yet a Just recipe for interactive SOPS editing, so this is an
intentional direct use of a mise-pinned CLI. Never commit a decrypted Secret or
place the private age identity in this tree.

After Flux bootstrap, use a scoped kubeconfig only for direct reads. Make
Flux-managed changes in Git and let Flux reconcile them. For bootstrap or recovery,
use the documented guarded `mise exec -- just bootstrap …` recipe rather than
`kubectl apply`.

See the root [`README.md`](../README.md) for guarded bootstrap workflows and the
[platform specification](../docs/specs/010-talos-flux-platform.md) for the Cilium,
Flux, and internal service foundation rationale. The
[Pi-hole integration guide](../docs/guides/pihole-integration.md) covers Pi-hole
reinstall and credential recovery. The [SOPS guide](../docs/guides/sops.md) covers
secret handling.
