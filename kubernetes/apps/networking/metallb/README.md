# MetalLB

MetalLB chart `0.16.1` advertises LoadBalancer addresses on the LAN in L2 mode.
This Kustomization owns one pool, `internal` (`192.168.90.30-192.168.90.38`,
`autoAssign` disabled), from which the internal Gateway explicitly requests
`192.168.90.30`, plus its L2Advertisement. FRR and FRR-K8s are disabled.

`192.168.90.39` is unallocated. It previously held a second pool, `public`, owned by
the dedicated public Plex Gateway; that plane was retired once direct remote access
was accepted, and the pool went with it.

Keep the ordering lesson it left behind if a second pool is ever added: MetalLB's
validating webhook refuses a pool overlapping one already defined, and Flux dry-runs
a Kustomization's objects against current cluster state before applying any of them.
Narrowing `internal` in the same Kustomization that creates the new pool therefore
deadlocks — at dry-run time `internal` still spans the wider range, so the new pool
is rejected and the narrowing that would free it never applies. Split them across
Kustomizations and order with `dependsOn`.

The router must exclude `192.168.90.30-192.168.90.39` from DHCP. Use
`just bootstrap foundation` for the guarded first reconciliation and
`just kube foundation-status` for inspection; see
[`docs/phase-7-foundation.md`](../../../../docs/phase-7-foundation.md).

All three nodes are schedulable control planes, so the Talos machine config
deletes `node.kubernetes.io/exclude-from-external-load-balancers` from
`machine.nodeLabels` (see `talos/patches/machine.yaml`). Talos adds and
reconciles that label on control-plane nodes, and MetalLB honors it: if every
node carries it, MetalLB reports "no available nodes" and never announces the
Gateway IP. Removing it only at the Kubernetes layer (`kubectl label`) does not
persist because Talos re-applies it from the machine config, so the fix must
live in the Talos config and be applied with `just talos apply`.
