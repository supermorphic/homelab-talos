# Kubernetes source contract

Flux is the sole reconciler for persistent Kubernetes state. After bootstrap,
change Flux-managed resources through Git; use scoped credentials for approved
reads and registered tests. Guarded bootstrap and recovery workflows own their
explicit exceptions.

## Layout and ownership

- The production root is `flux/clusters/prod/apps.yaml`. Its `cluster-apps`
  Kustomization selects explicit child entrypoints; a directory is not deployed
  merely because it exists. Root deletion uses `deletionPolicy: Orphan` so it
  cannot cascade into live applications.
- Put an application under `apps/<namespace>/<app>/` with an explicit `ks.yaml`
  and an `app/` directory. Keep its manifests, chart values, route, monitoring,
  and first-party configuration with that application.
- Use maintained Helm charts where appropriate, or focused native resources.
  Rendered chart output is validation material, not source to commit.
- Split controllers from their dependent custom resources. Express ordering with
  Flux `dependsOn`, readiness waiting, and health checks rather than directory
  order or numeric waves.
- Store Secrets with operator-supplied values as `*.sops.yaml`. Encrypt `data` and
  `stringData`; keep metadata reviewable. Controller-populated Secret declarations
  may omit both fields and remain plaintext. Never commit plaintext Secret values or an age identity.
  See the [SOPS guide](../docs/guides/sops-secret-operations.md).

## Bootstrap exceptions and network invariants

Cilium is installed before Flux because the nodes need a CNI to become Ready.
Its canonical values are in `apps/kube-system/cilium/app/values.yaml`; the guarded
`just bootstrap cilium` workflow installs that source first. Flux then adopts
the existing release through a protected, initially suspended Kustomization.
Do not apply its Flux objects manually. The [platform specification](../docs/specs/010-talos-flux-platform.md)
explains the adoption design.

A MetalLB pool transition that narrows an existing range and adds a new,
overlapping range cannot happen in one Flux Kustomization. Flux dry-runs the new
pool against the old live range before it applies the narrowing, and the MetalLB
webhook rejects the overlap. Split the changes into ordered Kustomizations using
`dependsOn`.

MetalLB excludes nodes carrying `node.kubernetes.io/exclude-from-external-load-balancers`.
Talos adds and reconciles that label on control-plane nodes. The source patch in
[`talos/patches/machine.yaml`](../talos/patches/machine.yaml) removes it so these
three schedulable control planes can announce LoadBalancer addresses. A manual
`kubectl label` removal is not durable; change and apply Talos source instead.

The Gateway owns the wildcard certificate in `networking`; application routes do
not copy its private key. Internal ExternalDNS only publishes routes with the
`external-dns.k8s.io/audience=internal` annotation. See the
[Pi-hole and ExternalDNS guide](../docs/guides/pihole-externaldns-operations.md).

Use `mise exec -- just kube` to find current Kubernetes workflows. The
[operator guides](../docs/README.md#guides) own application procedures; the
[platform specification](../docs/specs/010-talos-flux-platform.md) owns design
rationale.
