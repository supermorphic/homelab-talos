# Envoy Gateway

Envoy Gateway `v1.8.2` owns the Kubernetes Gateway API controller. It watches
only namespaces whose `gateway.supermorphic.com/access` label is `internal` or
`public`; every other namespace stays outside the controller's scope. The
separate `internal-gateway` package creates the GatewayClass, shared HTTPS
Gateway, and two-replica Envoy data plane at `192.168.90.30`.

The `public` access class is admitted by the controller but is not populated:
no namespace currently carries that label, and no Gateway, listener, data
plane, or route exists for it. Widening the selector alone changes nothing that
is reachable — a `public` Gateway only becomes real when its own namespace and
resources are added under a separate, explicitly reviewed change.

Applications attach portable HTTPRoutes from explicitly labeled namespaces.
They do not receive the wildcard TLS private key. Use the guarded foundation Just
workflows documented in the [root README](../../../../README.md); the
[platform specification](../../../../docs/specs/011-talos-flux-platform.md) records the
Gateway design rationale.
