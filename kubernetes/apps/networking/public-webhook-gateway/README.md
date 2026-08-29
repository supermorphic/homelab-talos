# Public webhook Gateway

This package owns the isolated public Envoy data plane for
`hooks.lab.supermorphic.com`. It uses `192.168.90.39` as the dedicated webhook
VIP, with the route reconciliation kept suspended until the operator publishes
and authenticates the canary.

The operator owns public DNS and router TCP/443 forwarding to this VIP. The
internal ExternalDNS controller does not publish the public name. Adding an n8n
workflow does not add a public route: each webhook path needs an explicitly
reviewed HTTPRoute and any required ReferenceGrant.
