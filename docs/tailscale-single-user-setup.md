# Tailscale single-user setup (operator walkthrough)

A step-by-step guide for a first-time Tailscale user to stand up the private remote
access path for this cluster: the Tailscale Kubernetes Operator + a shared HA ingress
`ProxyGroup`, and (in PR2) ntfy exposed privately to your tailnet.

This is the operator-facing companion to `docs/tailscale-operator.md` (which holds the
design rationale, the privileged-namespace exception, and the repo wiring). Work through
the numbered steps in order. Steps 1–7 unblock PR1's CI; steps 8–9 are needed before
rollout; steps 10–15 are rollout and acceptance.

> Security model: ntfy is **never** exposed to the public internet. LAN access stays on
> the internal gateway (`ntfy.lab.supermorphic.com`); off-site access is private over
> your tailnet. No public gateway, no port-forward, no Cloudflare Tunnel, no Tailscale
> Funnel.

---

## 1. Create the tailnet

Sign in at <https://login.tailscale.com> with your preferred identity provider
(Google/GitHub/Microsoft/email). That creates your **tailnet**. The Kubernetes Operator
is supported on all Tailscale plans; the personal (free) plan is sufficient.

## 2. Install Tailscale on your iPhone

Install the **Tailscale** app from the App Store, sign into the same account, and allow
it to install the iOS VPN configuration. For now:

```text
Tailscale:  Connected
Exit node:  None
```

Do **not** configure an exit node. Normal internet traffic should keep using Wi-Fi /
cellular directly — Tailscale is only your private overlay, not your internet gateway.

## 3. Add the Kubernetes tags

Admin Console → **Access controls** (<https://login.tailscale.com/admin/acls>). This is a
HuJSON (JSON-with-comments) editor. Start with:

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:ntfy": ["tag:k8s-operator"]
  }
}
```

The important relationship:

```text
tag:k8s-operator
       |
       | creates / manages
       v
    tag:k8s   (ProxyGroup proxy nodes)
```

The operator uses `tag:k8s-operator` for itself and `tag:k8s` for the proxies (this
matches our `values.yaml`: `operatorConfig.defaultTags: tag:k8s-operator`,
`proxyConfig.defaultTags: tag:k8s`), and the operator tag must own the proxy tag. We add
`tag:ntfy` so access can be granted specifically to ntfy later, not to everything
Kubernetes exposes.

## 4. Add the ntfy service policy

Because we use an HA `ProxyGroup`, the proxies advertise a separate **Tailscale Service**
representing ntfy. Add:

```jsonc
"autoApprovers": {
  "services": {
    "tag:ntfy": ["tag:k8s"]
  }
}
```

```text
Tailscale Service tagged tag:ntfy
             ^
             | may be advertised by
             |
        tag:k8s proxies
```

This matches Tailscale's HA ProxyGroup model: ProxyGroup devices advertise Tailscale
Services, and `autoApprovers.services` controls which tagged proxies may advertise each
tagged service.

## 5. Grant your tailnet access to ntfy

For your initial personal tailnet, add:

```jsonc
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["tag:ntfy"],
    "ip": ["tcp:443"]
  },
  {
    "src": ["autogroup:member"],
    "dst": ["tag:k8s:*"],
    "ip": ["icmp:*"]
  }
]
```

The first rule is the real ntfy permission (your devices → HTTPS 443 → ntfy). The second
grants ICMP reachability to the ProxyGroup devices: Tailscale currently requires clients
using HA ProxyGroup-backed Services to be able to ping the proxies (a documented
temporary limitation).

Your complete starting policy:

```jsonc
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"],
    "tag:ntfy": ["tag:k8s-operator"]
  },

  "autoApprovers": {
    "services": {
      "tag:ntfy": ["tag:k8s"]
    }
  },

  "grants": [
    {
      "src": ["autogroup:member"],
      "dst": ["tag:ntfy"],
      "ip": ["tcp:443"]
    },
    {
      "src": ["autogroup:member"],
      "dst": ["tag:k8s:*"],
      "ip": ["icmp:*"]
    }
  ]
}
```

**Save** the policy (the editor validates syntax live). You are **not** granting remote
access to your entire cluster — only to ntfy. Later you can add `tag:grafana`,
`tag:portainer`, `tag:plex`, etc. and grant each independently.

## 6. Create the Kubernetes Operator OAuth client

Admin Console → **Settings → Trust credentials**
(<https://login.tailscale.com/admin/settings/trust-credentials>) → generate an OAuth
client with these **write** permissions:

| Area | Scope | Access |
|---|---|---|
| General | Services | Read & Write |
| Devices | Core | Read & Write |
| Keys | Auth Keys | Read & Write |

Associate the credential with the tag **`tag:k8s-operator`** (it exists now because you
added it in step 3). Give it a descriptive name, e.g. `homelab-talos-k8s-operator`, and
generate it. You'll receive a **Client ID** and a **Client Secret** (looks like
`tskey-client-…`). Save both somewhere secure **temporarily** — the secret is shown only
once. **Do not commit them or paste them into chat.**

## 7. Put the OAuth credentials into SOPS

Run the guarded repo recipe (writes only the encrypted Secret; never echoes values):

```sh
TS_OAUTH_CLIENT_ID='<client-id>' \
TS_OAUTH_CLIENT_SECRET='<client-secret>' \
TAILSCALE_OPERATOR_SECRETS_CONFIRM='write:networking:tailscale-operator:sops' \
mise exec -- just repo tailscale-operator-secrets
```

This produces `kubernetes/apps/networking/tailscale-operator/app/oauth.sops.yaml`
(`Secret/operator-oauth` in namespace `tailscale`). Then run the offline validation:

```sh
mise exec -- just ci
```

Only encrypted values go into Git. **CI stays red until this Secret exists**, because the
app's kustomization references it.

## 8. Verify MagicDNS

Admin Console → **DNS** (<https://login.tailscale.com/admin/dns>). Verify **MagicDNS** is
enabled — Tailscale uses it to assign `*.ts.net` names inside your tailnet, which is what
gives ntfy its private HTTPS name. Do not change your existing internal DNS. You will
have two namespaces:

```text
LAN        ntfy.lab.supermorphic.com
Tailscale  ntfy.<tailnet>.ts.net
```

## 9. Enable HTTPS certificates

Still under **DNS**, find **HTTPS Certificates** and enable it (MagicDNS is required
first). Tailscale warns that the DNS names of issued certificates appear in public
Certificate Transparency logs — that does **not** make ntfy publicly reachable; only the
certificate name becomes public. ntfy's eventual name looks like
`ntfy.<your-tailnet>.ts.net`. Don't hard-code it yet — let the operator create the
service and use the address it reports (step 13).

## 10. Merge / deploy PR1

PR1 (`feat/tailscale-operator`) deploys, via GitOps only (do **not** `helm install`
manually):

```text
Tailscale Kubernetes Operator
        |
        v
HA ingress ProxyGroup (2 replicas)
```

The manifest (already in this repo):

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: ingress-proxies
spec:
  type: ingress
  replicas: 2
```

The app is committed `suspend: true`. After the PR merges and the Secret (step 7) is in
place, roll it out from `main`:

```sh
TAILSCALE_OPERATOR_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-operator' \
mise exec -- just bootstrap tailscale-operator
```

Then flip the Git source to `suspend: false`, commit, and push.

## 11. Verify PR1

Run the live verification:

```sh
mise exec -- just kube tailscale-operator-verify
```

It checks the Kustomization + HelmRelease are Ready, the operator Deployment rolled out,
and **both** ProxyGroup replicas are Ready. On the Tailscale **Machines** page you should
see:

```text
tailscale-operator     tag:k8s-operator
<two proxy devices>    tag:k8s
```

**Mandatory Cilium-compatibility test** (the verify step reminds you): from a device on
the tailnet, create a throwaway `Ingress` referencing `ingress-proxies` in front of any
test Service and confirm `tailnet client → ProxyGroup → Kubernetes Service` works with
valid HTTPS on the live Cilium cluster, then delete it. **Do not proceed to the ntfy PR
until this passes.**

## 12. PR2 exposes ntfy privately

ntfy's Ingress reuses the shared ProxyGroup and tags the advertised Tailscale Service as
`tag:ntfy`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ntfy
  namespace: ntfy
  annotations:
    tailscale.com/proxy-group: ingress-proxies
    tailscale.com/tags: tag:ntfy
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - ntfy          # short name; the operator publishes the full FQDN
  rules:
    - host: ntfy
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ntfy
                port:
                  number: 80
```

With ProxyGroup ingress, Tailscale creates a Tailscale Service with its own DNS identity,
advertised by the two ProxyGroup replicas.

## 13. Get the canonical ntfy URL

After PR2 deploys:

```sh
kubectl get ingress -n ntfy
```

```text
NAME   CLASS       HOSTS   ADDRESS
ntfy   tailscale   ntfy    ntfy.<your-tailnet>.ts.net
```

Use that actual `ADDRESS`. Set ntfy's config and the iPhone app to the **same** URL:

```yaml
base-url: "https://ntfy.<your-tailnet>.ts.net"
```

The LAN URL `https://ntfy.lab.supermorphic.com` still works for browser/CLI, but the
Tailscale URL is canonical for the iPhone / APNs workflow.

## 14. Configure the iPhone for normal use

Keep Tailscale connected for the first deployment:

```text
Tailscale:  ON
Exit node:  None
```

This does not turn your homelab into the phone's internet gateway. Traffic stays:

```text
Safari  -> google.com --------> Internet
ntfy    -> ntfy.<tailnet>.ts.net
                 |
                 v
              Tailscale ---> ntfy
```

Once stable, you can experiment with **VPN On Demand**: Tailscale → profile picture →
VPN On Demand (rules for Wi-Fi/cellular, and it can trigger on access to `*.ts.net`).
For reliability, begin with Tailscale continuously connected.

## 15. Final acceptance test

Success is not simply opening ntfy — it's the real off-site push path:

```text
Phone locked, Wi-Fi off, cellular active, Tailscale connected
       |
       v
Alertmanager / Seerr
       |
       v  (publish to the in-cluster ntfy Service)
ntfy Kubernetes Service
       |
       v  (upstream poll → APNs wake)
ntfy.sh / APNs
       |
       v
iPhone ntfy app
       |
       v  (retrieve body over the tailnet)
ntfy.<tailnet>.ts.net
       |
       v
message retrieved
```

Once that works reliably, you have the foundation:

```text
LAN-only services        -> internal Gateway
Private remote services  -> Tailscale
Public services          -> explicit, service-by-service decision
```

The same Tailscale foundation can later privately serve Grafana, Portainer, Plex for your
own devices, or Kubernetes administration — without making any of them publicly
reachable.
