# Tailscale access for `*.lab.supermorphic.com`

Operator runbook for reaching the internal `*.lab.supermorphic.com` applications from
authorized Tailscale clients — **same URLs as on the home LAN**, no per-app Tailscale
hostnames, no Funnel, no public exposure.

## Architecture (Decision C — split DNS + narrow subnet router)

```text
tailnet client
  → split-DNS query lab.supermorphic.com → Pi-hole 192.168.90.2   (via Connector /32 route)
  → A 192.168.90.30
  → HTTPS → Envoy Gateway VIP 192.168.90.30                       (via Connector /32 route)
  → existing HTTPRoute + wildcard TLS (unchanged)
```

- **Tailscale** provides the private path to two LAN IPs only.
- **Pi-hole** owns `lab.supermorphic.com` (per-hostname A records → `192.168.90.30`,
  published by external-dns; no DNS change is needed to add a new app).
- **Envoy Gateway** terminates the real Let's Encrypt wildcard TLS and routes by hostname.
- **Flux/Git** owns Kubernetes desired state; **apps** own their own authentication.

Adding a new `foo.lab.supermorphic.com` needs no Tailscale change — once its normal
HTTPRoute (`external-dns.k8s.io/audience: internal`) exists, it is remotely reachable.

## Repository resources

| Resource | Path |
|---|---|
| Connector `lab-subnet-router` (HA `replicas: 2`, `hostnamePrefix`, `tag:lab-router`, two `/32`s) | `kubernetes/apps/networking/tailscale-operator/subnet-router/connector.yaml` |
| ProxyClass `lab-subnet-router` (hard node spread) | `.../subnet-router/proxyclass.yaml` |
| Flux Kustomization `tailscale-operator-subnet-router` (active, `suspend: false`) | `.../tailscale-operator/ks.yaml` |
| Static validation (in `just ci`) | `scripts/validate/tailscale-subnet-router.sh` |
| Guarded rollout | `just bootstrap tailscale-subnet-router` |
| Live verification (operator) | `scripts/verify/tailscale-subnet-router.sh` |

## The two routes (least privilege)

Only these are advertised. Never the LAN `/24`, Pod CIDR (`10.244.0.0/16`), or Service
CIDR (`10.96.0.0/12`).

```text
192.168.90.2/32    # Pi-hole DNS resolver
192.168.90.30/32   # Envoy internal Gateway VIP
```

---

## Setup sequence

### Step 1 — tailnet policy (before bootstrap)

The operator can only create the Connector devices if the OAuth client (tagged
`tag:k8s-operator`) **already owns** `tag:lab-router`, so this ACL change must be saved
**before** the guarded bootstrap. These steps are **additive** — do not replace the
existing policy (the full annotated policy lives in `docs/tailscale-operator.md`; the
initial-setup walkthrough is `docs/tailscale-single-user-setup.md`).

1. Open Admin Console → **Access controls** (<https://login.tailscale.com/admin/acls>).
   The console has two views — a **Visual Editor** and a **JSON Editor** — that edit the
   **same policy**; changes in one show up in the other. The steps below use the JSON
   Editor.
2. Create the tag and set its owner. In `tagOwners`, add one line so the operator's tag
   owns `tag:lab-router` (same ownership model as `tag:ntfy`):

   ```jsonc
   "tagOwners": {
     // ...keep every existing entry (tag:k8s, tag:ntfy, ...)...
     "tag:lab-router": ["tag:k8s-operator"]
   },
   ```

   (Visual Editor equivalent: create the tag `lab-router` — enter it without the `tag:`
   prefix; the console adds it — and set `k8s-operator` as its owner.)
3. In `autoApprovers.routes`, map each exact route to `tag:lab-router`. This makes route
   approval part of the policy, so every tagged replica is approved automatically,
   including replacement devices:

   ```jsonc
   "autoApprovers": {
     // ...keep every existing entry...
     "routes": {
       "192.168.90.2/32": ["tag:lab-router"],
       "192.168.90.30/32": ["tag:lab-router"]
     }
   },
   ```

4. In `grants`, add the two least-privilege subnet-router rules — DNS to the Pi-hole
   resolver, HTTPS to the Envoy Gateway VIP. Never the LAN /24 or the Pod/Service CIDRs:

   ```jsonc
   { "src": ["autogroup:member"], "dst": ["192.168.90.2/32"],  "ip": ["tcp:53", "udp:53"] },
   { "src": ["autogroup:member"], "dst": ["192.168.90.30/32"], "ip": ["tcp:443"] }
   ```

5. **Save** the policy. The console validates the JSON and shows a preview diff — confirm
   it contains only these additions. No OAuth-client change is needed.

> `autogroup:member` is intentional **only** for the current single-user tailnet. Before
> onboarding another user, replace it with a dedicated group whose membership is
> explicitly reviewed — a member who can reach one `*.lab.supermorphic.com` host over the
> shared Gateway VIP :443 can reach them all (shared-IP L4 limitation; per-app isolation
> stays with app authentication).

### Step 2 — guarded rollout

From a clean checkout synchronized with the current `origin/main` source:

```bash
TAILSCALE_SUBNET_ROUTER_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-subnet-router' \
  mise exec -- just bootstrap tailscale-subnet-router
```

This validates, confirms the Kustomization is suspended in Git and live, resumes/reconciles
**only** `tailscale-operator-subnet-router`, waits for Ready, and runs
`tailscale-subnet-router-verify`. On failure it re-suspends the Kustomization (resources
preserved).

The verify confirms **structural** readiness — Connector `ConnectorReady`, **2** devices,
**2** pods on distinct nodes, and that the Connector spec and status both report exactly
the two `/32`s — and polls those (they are eventually consistent after reconcile). In
operator v1.98.9, `.status.subnetRoutes` is a comma-separated copy of the configured spec
routes; it does **not** prove tailnet route approval. Confirm automatic approval in step 3;
the off-LAN client acceptance in step 5 proves that the routes carry real traffic.

### Step 3 — verify automatic route approval

The `autoApprovers.routes` policy from step 1 automatically approves both exact `/32`s for
every device tagged `tag:lab-router`. Two replicas create **two** tailnet devices, and both
must show both routes for real failover, but no per-device approval click is required.

1. Admin Console → **Machines**.
2. Locate **both** `lab-subnet-router-*` devices.
3. Confirm each device shows these routes as approved/enabled:
   - `192.168.90.2/32` (DNS resolver)
   - `192.168.90.30/32` (Gateway VIP)
4. Confirm neither device advertises any other subnet.
5. Re-run `mise exec -- just kube tailscale-subnet-router-verify` to confirm the Connector
   remains reconciled, then use step 5 to prove the routes carry real client traffic.

> Kubernetes status cannot prove tailnet approval — `.status.subnetRoutes` mirrors the
> configured `advertiseRoutes` string. The guarded verifier proves reconciliation, the Admin
> Console confirms the auto-approval policy took effect, and client acceptance proves route
> usability. If either route is pending, fix `autoApprovers.routes` or the device's
> `tag:lab-router`; do not use a manual approval to hide a policy error. Keep the policy
> scoped to the exact `/32`s — never broaden it to the LAN `/24` or Pod/Service CIDRs.

### Step 4 — split DNS

1. Admin Console → **DNS**.
2. Keep **MagicDNS** enabled.
3. **Add nameserver → Custom** → `192.168.90.2`.
4. Enable **Restrict to search domain** → `lab.supermorphic.com`.
5. Save. Do **not** enable a global DNS override.

### Step 5 — client acceptance

> **Nothing under `*.lab.supermorphic.com` resolves off-LAN until steps 3 and 4 are done,
> and only while Tailscale is Connected.** If a page won't load, you have almost certainly
> encountered a route auto-approval problem (step 3), missed split DNS (step 4), or turned
> Tailscale off — see the checklist in each client section below and Troubleshooting.

Run the checks below from a real client (MacBook and/or iPhone). Complete durable activation
only after they pass.

---

## Client acceptance (MacBook, off the home LAN)

```bash
# Resolver selection: lab.supermorphic.com must map to 192.168.90.2
scutil --dns | grep -A2 lab.supermorphic.com      # or: tailscale dns status
# Route selection: the Gateway /32 goes through the Tailscale interface
route -n get 192.168.90.30
# DNS answer via the private resolver
dscacheutil -q host -a name homepage.lab.supermorphic.com   # → 192.168.90.30
# HTTPS with a valid chain (never -k)
curl -I https://homepage.lab.supermorphic.com
curl -I https://grafana.lab.supermorphic.com
curl -I https://portainer.lab.supermorphic.com
```

Then the **negative test**: disconnect Tailscale while off-LAN and confirm the hosts are
unreachable (the public Internet must not be a fallback).

### iPhone (primary acceptance)

**Prerequisites (must all be true first):** step 3 confirms both `/32`s were automatically
approved on **both** `lab-subnet-router-*` devices; step 4 configured split-DNS nameserver
`192.168.90.2` restricted to `lab.supermorphic.com`; and the Tailscale app is **Connected**.
Without these the pages will not load (by design — nothing is public).

1. Open the **Tailscale app** and confirm it is **Connected** (toggle ON). Off-LAN with
   Tailscale **off**, `*.lab.supermorphic.com` is intentionally unreachable.
2. Confirm the device is using Tailscale DNS: Tailscale app → the device should show DNS is
   in use (the split-DNS nameserver from step 4 applies automatically once Connected).
3. Turn **Wi-Fi off** so the test uses cellular (proves it works off the home LAN).
4. In Safari open `https://homepage.lab.supermorphic.com`; from Homepage open representative
   services (Grafana, Portainer, Seerr, ntfy).
5. Confirm: no certificate warning; apps authenticate normally.
6. **Negative test:** turn Tailscale **off** (still on cellular) → confirm the hosts are now
   unreachable (the public Internet must not be a fallback).

> If a page does not load with Tailscale Connected: it is usually step 3
> (`autoApprovers.routes` did not approve both devices) or step 4 (split DNS is unset or the
> device is not yet using Tailscale DNS — toggle Tailscale off/on). See Troubleshooting.

### On-LAN overlap test

With Tailscale connected **on the home LAN**, repeat a DNS + HTTPS request. Because a `/32`
is more specific than the local `192.168.90.0/24`, the client routes Pi-hole and the Gateway
**through the Connector** (a documented Tailscale overlapping-subnet behavior). Confirm it
still succeeds — and note that home access to those two IPs then depends on Connector
availability while Tailscale is up.

### Step 6 — durable activation

For an initially staged deployment, make the tested state durable after client acceptance:

1. Set `tailscale-operator-subnet-router` to `suspend: false` in
   `kubernetes/apps/networking/tailscale-operator/ks.yaml`.
2. Run `mise exec -- just ci`.
3. Publish the validated change through the repository's normal Git workflow and wait for
   Flux to reconcile it.
4. Run `mise exec -- just kube tailscale-subnet-router-verify`.

---

## Security properties

- No unauthenticated Internet client can reach the Gateway (no Funnel, no public LB).
- Only two `/32`s are advertised — no LAN `/24`, Pod, or Service CIDR.
- OAuth credentials stay SOPS-encrypted; no auth keys in manifests.
- App authentication remains enabled and is the per-app isolation boundary.
- **Shared-IP L4 limitation:** all apps share `192.168.90.30:443`, so an L4 grant cannot
  distinguish `grafana.lab…` from `seerr.lab…`. `autogroup:member` is acceptable only on
  this single-user tailnet; replace it with a reviewed group before adding users.
- Disconnecting Tailscale off-LAN removes access.

---

## Maintenance

### DNS resolver replacement (Pi-hole → Technitium)

1. Deploy/validate Technitium and confirm it answers `lab.supermorphic.com` locally.
2. Add Technitium's exact `/32` route(s) to `autoApprovers.routes` and the required DNS
   grants in the tailnet policy.
3. Add the same `/32` route(s) to the Connector `advertiseRoutes`; run `just ci`; roll out;
   confirm both devices show the new routes as automatically approved.
4. Add the new restricted split-DNS nameserver(s); test tailnet resolution.
5. Remove the Pi-hole restricted resolver, then remove the old `192.168.90.2/32` route and
   its policy entries once no client depends on it. If Technitium has two resolvers,
   configure two restricted nameservers.

### Gateway VIP change

1. Update authoritative internal DNS as normal.
2. Add the new exact `/32` to `autoApprovers.routes` and the HTTPS grant.
3. Update the Connector `advertiseRoutes`; run `just ci`; roll out; confirm both devices
   show the route as automatically approved; validate from a client.
4. Remove the old route and its policy entries.

### New client onboarding

Install Tailscale → authenticate to the tailnet → accept DNS → open Homepage → confirm scope.
No per-application configuration is required.

---

## Troubleshooting

- **DNS works on LAN but not on Tailscale:** client accepts Tailscale DNS; restricted domain
  is exactly `lab.supermorphic.com`; `autoApprovers.routes` approved
  `192.168.90.2/32` on a *connected* replica; the grant permits `tcp/udp:53`; Pi-hole
  DNS-rebinding protection is not dropping the private-IP answer for the zone.
- **DNS resolves but HTTPS fails:** `autoApprovers.routes` approved `192.168.90.30/32`; the
  grant permits `tcp:443`; Envoy Gateway `internal` is Programmed; the app's HTTPRoute is
  Accepted; TLS/backend is healthy.
- **One app fails, others work:** routing/DNS are fine — check that app's HTTPRoute hostname,
  backend Service, auth, and base-URL/Host handling.
- **Works on Wi-Fi but not cellular:** a Tailscale path/DNS issue — re-check on-device tailnet
  state and split DNS.
- **Only one replica healthy / both on one node:** the ProxyClass hard spread
  (`DoNotSchedule`) keeps one replica per node; if a replica is Pending, a node is
  unavailable — this is a deliberate availability signal, not a bug to work around by
  weakening the constraint.
