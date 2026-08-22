# Configure the Tailscale Kubernetes Operator

The Tailscale Kubernetes Operator and the shared two-replica ingress `ProxyGroup`
provide private tailnet access for selected in-cluster services. Current source is in
[`kubernetes/apps/networking/tailscale-operator/`](../../kubernetes/apps/networking/tailscale-operator/).

## Tailnet prerequisites

Complete these settings in the Tailscale admin console before a fresh deployment.

### OAuth client

Create an OAuth client tagged `tag:k8s-operator` with write access for:

- Devices / Core;
- Keys / Auth Keys; and
- Services.

Store the client ID and secret securely. They belong only in the SOPS-encrypted
`Secret/operator-oauth`.

### Access policy

Do not use an allow-all grant. The current single-user policy needs these ownership and
approval relationships:

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:ntfy": ["tag:k8s-operator"],
    "tag:lab-router": ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "services": {
      "tag:ntfy": ["tag:k8s"]
    },
    "routes": {
      "192.168.90.2/32": ["tag:lab-router"],
      "192.168.90.30/32": ["tag:lab-router"]
    }
  },
  "grants": [
    { "src": ["autogroup:member"], "dst": ["tag:ntfy"], "ip": ["tcp:443"] },
    { "src": ["autogroup:member"], "dst": ["tag:k8s"], "ip": ["icmp:*"] },
    { "src": ["autogroup:member"], "dst": ["192.168.90.2/32"], "ip": ["tcp:53", "udp:53"] },
    { "src": ["autogroup:member"], "dst": ["192.168.90.30/32"], "ip": ["tcp:443"] }
  ]
}
```

Use `tag:k8s`, not `tag:k8s:*`, for the ICMP destination. Add a distinct tag and grant
for each future private service instead of widening access.

`autogroup:member` is acceptable only while the tailnet has one user. Before adding a
user, replace it with a group whose membership is explicitly reviewed. All internal
applications share `192.168.90.30:443`, so the subnet-router grant cannot distinguish
one hostname from another; application authentication remains the per-application
boundary.

### DNS and certificates

Enable MagicDNS and HTTPS certificates in the Tailscale DNS settings. Tailscale Ingress
cannot provide its private HTTPS name without both.

## Write the OAuth Secret

Load the repository SOPS age identity, then run:

```bash
TS_OAUTH_CLIENT_ID='<client-id>' \
TS_OAUTH_CLIENT_SECRET='<client-secret>' \
TAILSCALE_OPERATOR_SECRETS_CONFIRM='write:networking:tailscale-operator:sops' \
  mise exec -- just repo tailscale-operator-secrets
```

The recipe writes only
`kubernetes/apps/networking/tailscale-operator/app/oauth.sops.yaml`. Commit the
ciphertext through the normal pull-request workflow.

## Deploy or recover the operator

For a deliberately suspended or fresh installation, run the guarded bootstrap from the
deployed `main` source:

```bash
TAILSCALE_OPERATOR_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-operator' \
  mise exec -- just bootstrap tailscale-operator
```

Then run the read-only verifier:

```bash
mise exec -- just kube tailscale-operator-verify
```

The operator Deployment and both `ingress-proxies` replicas must be Ready. The Tailscale
Machines page must show the operator device tagged `tag:k8s-operator` and two proxy
devices tagged `tag:k8s`.

After a fresh deployment, perform a controlled compatibility test from a tailnet client
through an `ingress-proxies`-backed test Ingress to a test Service. Require valid HTTPS
and remove the test resource after it passes. Persistent test resources must go through
Git unless an approved repository workflow owns the ephemeral test and cleanup.

## Configure services and subnet access

An application exposes itself privately by creating a Tailscale Ingress that references
`tailscale.com/proxy-group: ingress-proxies` and its service-specific tag. ntfy uses
`tag:ntfy`.

The separate `lab-subnet-router` Connector advertises only the Pi-hole and internal
Gateway `/32` routes. Follow [Tailscale lab-domain access](tailscale-lab-domain.md) for
route, split-DNS, client acceptance, maintenance, and troubleshooting.

## Rotate or recover credentials

Create a replacement OAuth client with the same tag and scopes. Rerun the SOPS writer,
publish the ciphertext change, wait for Flux reconciliation, and rerun the verifier.
Revoke the old OAuth client only after the operator and both proxy replicas are Ready.

To disable the operator, set its Flux Kustomization to `suspend: true` through Git. This
does not remove tailnet ACL, tag, service, or device state. Review and remove unused
external state separately after confirming that no service depends on it.
