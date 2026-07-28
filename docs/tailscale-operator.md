# Tailscale Kubernetes Operator

Reusable cluster infrastructure that connects private in-cluster services to the
tailnet. It is deployed as `kubernetes/apps/networking/tailscale-operator/` (namespace
`tailscale`) and provides:

- the **Tailscale operator** (reconciles Ingress/Service exposure onto the tailnet), and
- a shared, highly-available **ingress `ProxyGroup`** named `ingress-proxies`
  (`type: ingress`, `replicas: 2`).

Any private service (starting with ntfy in a later PR) exposes itself by creating an
`Ingress` with `ingressClassName: tailscale` and the annotation
`tailscale.com/proxy-group: ingress-proxies`. Treat the ProxyGroup as shared networking
infrastructure — do not give each service its own single-replica proxy.

### Two Flux Kustomizations (CRD ordering)

`ks.yaml` defines **two** Flux Kustomizations, deliberately:

- `tailscale-operator` (`./app`) — installs the operator, which registers the
  `tailscale.com` CRDs (including `ProxyGroup`).
- `tailscale-operator-proxygroup` (`./proxygroup`) — the `ProxyGroup` CR, with
  `dependsOn: tailscale-operator`.

They must be separate: Flux dry-runs every object in a Kustomization atomically before
applying any, so a `ProxyGroup` in the operator Kustomization fails the dry-run with
`no matches for kind "ProxyGroup"` (the CRD does not exist yet) and deadlocks the whole
apply — the operator that would install the CRD never deploys. `dependsOn` gates the CR
on the operator being Ready, so the CRD always exists first. The ProxyGroup Kustomization
is left `suspend: false` (its `dependsOn` is the real gate); only the operator
Kustomization is staged `suspend: true` for the guarded bootstrap.

## Scope (intentionally minimal)

This deployment provides **operator + ingress ProxyGroup only**. The following are
explicitly out of scope and disabled:

- Kubernetes API server proxy (`apiServerProxyConfig.mode: "false"`).
- Subnet routers, exit nodes, cluster egress proxies.
- Tailscale **Funnel** (public internet exposure). Funnel is a possible *future*
  alternative if VPN-independent public access is ever wanted; it is **not** enabled and
  not required for ntfy.

## Security posture: privileged namespace exception

Tailscale proxy Pods (the operator and the ProxyGroup ingress proxies) require
`/dev/net/tun` and run as **privileged** containers with `NET_ADMIN`. The `tailscale`
namespace therefore carries `pod-security.kubernetes.io/enforce: privileged`.

This is a **narrowly-scoped, deliberate exception** limited to the `tailscale`
namespace. Prior art in this repo: `trivy-system` runs `enforce: privileged` for the
same class of host-access infrastructure workload. We do **not** add device-plugin /
userspace-networking hardening here; if the repo's security goals later justify it, a
`ProxyClass` hardening path can be introduced, but it is not warranted for a
home-cluster ingress path today.

## Tailnet prerequisites (manual, operator-run — do these BEFORE rollout)

> **First-time users:** follow the step-by-step
> [`docs/tailscale-single-user-setup.md`](tailscale-single-user-setup.md) walkthrough,
> which covers account creation, the iPhone client, and the exact console clicks. The
> sections below are the reference summary.

The operator will not become Ready until the tailnet side is prepared.

### 1. OAuth client

In the Tailscale admin console, create an **OAuth client** with:

- Tag: `tag:k8s-operator` (the client must be tagged so the operator can mint tagged
  auth keys).
- Scopes (write):
  - **Devices / Core: write**
  - **Keys / Auth Keys: write**
  - **Services: write** (required for the ingress ProxyGroup to advertise a Tailscale
    Service)

Record the client ID and secret; they go only into the SOPS Secret (below).

### 2. ACL policy — least privilege (NOT allow-all)

Even on a personal tailnet, do **not** use a blanket `"*":"*"` grant. Give each exposed
service its own tag (`tag:ntfy`), scope reachability to it, and keep tag ownership with
`tag:k8s-operator`:

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s":          ["tag:k8s-operator"],
    "tag:ntfy":         ["tag:k8s-operator"],
    // Subnet router for the *.lab.supermorphic.com split-DNS design.
    "tag:lab-router":   ["tag:k8s-operator"]
  },
  "autoApprovers": {
    // Auto-approve the Tailscale Service the ingress ProxyGroup advertises for ntfy.
    "services": {
      "tag:ntfy": ["tag:k8s"]
    }
    // NOTE: the lab-subnet-router /32 routes are approved MANUALLY on each replica
    // device (see docs/tailscale-lab-domain.md). `autoApprovers.routes` is a deferred
    // hardening step, added only after the manual workflow is proven.
  },
  "grants": [
    // Your devices may reach ntfy over HTTPS.
    { "src": ["autogroup:member"], "dst": ["tag:ntfy"],  "ip": ["tcp:443"] },
    // HA ProxyGroup-backed Services currently also require ICMP to the proxies
    // (documented temporary Tailscale limitation). dst is "tag:k8s" — NOT
    // "tag:k8s:*" (the console rejects the :* form with `tag not found`).
    { "src": ["autogroup:member"], "dst": ["tag:k8s"], "ip": ["icmp:*"] },
    // lab-subnet-router: reach ONLY the Pi-hole resolver (DNS) and the Envoy Gateway VIP
    // (HTTPS) behind the subnet router. Never the LAN /24, Pod, or Service CIDRs.
    { "src": ["autogroup:member"], "dst": ["192.168.90.2/32"],  "ip": ["tcp:53", "udp:53"] },
    { "src": ["autogroup:member"], "dst": ["192.168.90.30/32"], "ip": ["tcp:443"] }
  ]
}
```

Add a new `tag:<service>` + grant for each future private service rather than widening
access. See the walkthrough for the full annotated policy.

The `autogroup:member` source above is intentional **only** because this tailnet is
single-user today. Before onboarding any additional user, replace `autogroup:member`
with a dedicated group whose membership is explicitly reviewed — a member who can reach
one `lab.supermorphic.com` host over the shared Gateway IP:443 can reach them all
(shared-IP L4 limitation; per-app isolation stays with app authentication). The
subnet-router grants and the `*.lab.supermorphic.com` runbook are documented in
`docs/tailscale-lab-domain.md`.

### 3. MagicDNS and HTTPS certificates

Enable, in the tailnet DNS settings:

- **MagicDNS**
- **HTTPS certificates**

These make the operator publish a valid `*.ts.net` HTTPS name for each Ingress. Without
them, L7 Tailscale Ingress cannot serve TLS.

## Rollout (operator-run)

1. Write the OAuth Secret (never echoes values):

   ```sh
   TS_OAUTH_CLIENT_ID='<client-id>' \
   TS_OAUTH_CLIENT_SECRET='tskey-client-<...>' \
   TAILSCALE_OPERATOR_SECRETS_CONFIRM='write:networking:tailscale-operator:sops' \
   mise exec -- just repo tailscale-operator-secrets
   ```

   This writes only the encrypted
   `kubernetes/apps/networking/tailscale-operator/app/oauth.sops.yaml`
   (`Secret/operator-oauth` in `tailscale`).

2. Validate and merge the PR (the app is committed `suspend: true`).

3. After merge, roll out from `main`:

   ```sh
   TAILSCALE_OPERATOR_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-operator' \
   mise exec -- just bootstrap tailscale-operator
   ```

4. Run the live verification:

   ```sh
   mise exec -- just kube tailscale-operator-verify
   ```

5. **Mandatory Cilium-compatibility test** (the verify step reminds you): from a device
   on the tailnet, create a throwaway `Ingress` referencing `ingress-proxies` in front
   of any test Service, confirm `tailnet client -> ProxyGroup -> Kubernetes Service`
   works with valid HTTPS on the live Cilium cluster, then delete it. Do **not** proceed
   to the ntfy PR until this passes.

6. Flip the Git source to `suspend: false`, commit, push, and re-run
   `mise exec -- just kube tailscale-operator-verify`.

## Rollback

Suspend the Kustomization (`flux suspend kustomization tailscale-operator`) — the
`bootstrap` recipe already re-suspends on failure. Rotating the OAuth client is done by
re-running the secrets recipe with new credentials, then reconciling. Removing the
operator does not delete tailnet ACL state; prune unused tags/services in the admin
console separately.
