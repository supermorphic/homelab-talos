# MetalLB

MetalLB chart `0.16.1` advertises LoadBalancer addresses on the LAN in L2 mode.
Two pools exist and `autoAssign` is disabled on both: `internal`
(`192.168.90.30-192.168.90.38`), from which the internal Gateway explicitly
requests `192.168.90.30`; and `public` (`192.168.90.39/32`), reserved for the
dedicated public Plex Gateway and claimed only while that Kustomization is
resumed. Each pool has its own L2Advertisement. FRR and FRR-K8s are disabled.

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
