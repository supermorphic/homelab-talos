# Cilium

Cilium is the production cluster's CNI, Kubernetes NetworkPolicy engine,
kube-proxy replacement, and initial network-observability layer. The bootstrap workflow
installs the Helm release before Flux exists; Flux then adopts that same release.

## Ownership Contract

- Release: `cilium`
- Namespace and Helm storage namespace: `kube-system`
- Chart: `oci://quay.io/cilium/charts/cilium`
- Chart version: `1.19.6`
- Canonical configuration: `app/values.yaml`

The bootstrap recipe passes `values.yaml` directly to Helm. The app
Kustomization turns the same file into the watched `cilium-values` ConfigMap used
by the HelmRelease. Flux first publishes this Kustomization suspended and with
orphan/prune protection. `just bootstrap flux-adopt-cilium` verifies a no-rollout
ownership transfer and stages the durable unsuspend change. Do not duplicate
values in the HelmRelease or commit rendered chart manifests.

The initial network uses IPv4 VXLAN tunneling. Native routing, BGP, Cilium L2
announcements, BIG TCP, BBR, netkit, DSR, Maglev, Gateway API, and Cilium Envoy
remain disabled until a measured requirement and a separate review justify them.
MetalLB and Envoy Gateway own LAN address announcement and ingress.

## Operator Interface

Use only the repository Just workflows documented in
[`../../../../README.md`](../../../../README.md). The
[platform specification](../../../../docs/specs/010-talos-flux-platform.md) records the
bootstrap and adoption rationale.
Do not run an ad hoc Helm installation because Flux adoption depends on the
release name, namespace, chart, and values remaining identical.
