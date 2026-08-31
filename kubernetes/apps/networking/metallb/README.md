# MetalLB

MetalLB chart `0.16.1` advertises LoadBalancer addresses on the LAN in L2 mode.
This Kustomization owns one pool, `internal` (`192.168.90.30-192.168.90.38`,
`autoAssign` disabled), from which the internal Gateway explicitly requests
`192.168.90.30`, plus its L2Advertisement. FRR and FRR-K8s are disabled.

`192.168.90.39` is the dedicated webhook VIP. The separate
`public-webhooks` pool assigns it only to the isolated public Envoy data plane.
The operator owns router TCP/443 forwarding to this address. Internal ExternalDNS
publishes the Pi-hole view of the public hostname to this VIP from an annotated
`DNSEndpoint`; UniFi DDNS updates the separate public Cloudflare record. Adding an
n8n workflow does not add a public route.

Keep the ordering lesson it left behind if a second pool is ever added: MetalLB's
validating webhook refuses a pool overlapping one already defined, and Flux dry-runs
a Kustomization's objects against current cluster state before applying any of them.
Narrowing `internal` in the same Kustomization that creates the new pool therefore
deadlocks — at dry-run time `internal` still spans the wider range, so the new pool
is rejected and the narrowing that would free it never applies. Split them across
Kustomizations and order with `dependsOn`.

The router must exclude `192.168.90.30-192.168.90.39` from DHCP. Use
`just bootstrap foundation` for guarded first reconciliation and
`just kube foundation-status` for inspection. The
[platform specification](../../../../docs/specs/010-talos-flux-platform.md) records the
addressing and availability rationale.

All three nodes are schedulable control planes, so the Talos machine config
deletes `node.kubernetes.io/exclude-from-external-load-balancers` from
`machine.nodeLabels` (see `talos/patches/machine.yaml`). Talos adds and
reconciles that label on control-plane nodes, and MetalLB honors it: if every
node carries it, MetalLB reports "no available nodes" and never announces the
Gateway IP. Removing it only at the Kubernetes layer (`kubectl label`) does not
persist because Talos re-applies it from the machine config, so the fix must
live in the Talos config and be applied with `just talos apply`.
