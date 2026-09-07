# Public webhook Gateway

This package owns the isolated public Envoy data plane for
`hooks.lab.supermorphic.com`. It uses `192.168.90.39` as the dedicated webhook
VIP. Initial route activation requires the operator to publish and authenticate
the canary. The HTTPRoute allowlists only the exact `/webhook/platform-canary` and
`/webhook/theirstack-jobs` paths to `automation/n8n:5678`. Each integration must pass
the [activation procedure](../../../../docs/guides/n8n-operations.md#add-a-public-webhook-integration)
before its route change merges; repository validation alone does not prove provider
acceptance.

The package also owns an annotated `DNSEndpoint` that makes the internal Pi-hole
answer resolve this hostname to the dedicated VIP before route activation. The
operator owns the one UniFi Cloudflare DDNS profile and router TCP/443 forwarding;
the public WAN address is never stored in Git. Adding an n8n workflow does not add
a DNS record or public route: each webhook path needs an explicitly reviewed
HTTPRoute and any required ReferenceGrant.
