# MetalLB

MetalLB chart `0.16.1` advertises LoadBalancer addresses on the LAN in L2 mode.
This Kustomization owns one pool, `internal` (`192.168.90.30-192.168.90.38`,
`autoAssign` disabled), from which the internal Gateway explicitly requests
`192.168.90.30`, plus its L2Advertisement. FRR and FRR-K8s are disabled.

A second pool, `public` (`192.168.90.39/32`), is defined by the dedicated public
Plex Gateway in
[`../public-gateway/app/address-pool.yaml`](../public-gateway/app/address-pool.yaml)
rather than here, so `.39` is claimed only while that suspended Kustomization is
resumed. That placement is required, not stylistic: MetalLB's validating webhook
refuses a pool overlapping one already defined, and Flux dry-runs a Kustomization's
objects against current cluster state before applying any of them. Shipping the
narrowing of `internal` beside the creation of `public` deadlocks — at dry-run time
`internal` still spans `.30-.39`, so `.39/32` is rejected and the narrowing that
would free it never applies. `dependsOn: metallb-config` orders them correctly.

The router must exclude `192.168.90.30-192.168.90.39` from DHCP. Use
`just bootstrap foundation` for the guarded first reconciliation and
`just kube foundation-status` for inspection; see
[`docs/phases/phase-7-foundation.md`](../../../../docs/phases/phase-7-foundation.md).

All three nodes are schedulable control planes, so the Talos machine config
deletes `node.kubernetes.io/exclude-from-external-load-balancers` from
`machine.nodeLabels` (see `talos/patches/machine.yaml`). Talos adds and
reconciles that label on control-plane nodes, and MetalLB honors it: if every
node carries it, MetalLB reports "no available nodes" and never announces the
Gateway IP. Removing it only at the Kubernetes layer (`kubectl label`) does not
persist because Talos re-applies it from the machine config, so the fix must
live in the Talos config and be applied with `just talos apply`.
