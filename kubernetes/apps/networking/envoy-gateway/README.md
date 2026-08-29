# Envoy Gateway

Envoy Gateway `v1.8.2` owns the Kubernetes Gateway API controller. It watches
only namespaces whose `gateway.supermorphic.com/access` label is `internal` or
`public`; every other namespace stays outside the controller's scope. The
separate `internal-gateway` package creates the GatewayClass, shared HTTPS
Gateway, and two-replica Envoy data plane at `192.168.90.30`.

The `public` access class is used only by the separate public webhook Gateway in
`networking-public`. That isolated data plane uses the dedicated
`192.168.90.39` webhook VIP. Its listener admits routes only from its own
namespace, so adding an n8n workflow does not add a public route.

The operator owns public DNS and router TCP/443 forwarding for the public VIP.
The internal ExternalDNS controller does not publish the public hostname.

Applications attach portable HTTPRoutes from explicitly labeled namespaces.
They do not receive the wildcard TLS private key. Use the guarded foundation Just
workflows documented in the [root README](../../../../README.md); the
[platform specification](../../../../docs/specs/010-talos-flux-platform.md) records the
Gateway design rationale.
