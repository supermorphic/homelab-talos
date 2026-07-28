# Tailscale Access for `*.lab.supermorphic.com`
## Codex Agent Implementation Plan + Human Operator Runbook

**Repository:** `homelab-talos`
**Objective:** Make the existing internal `*.lab.supermorphic.com` application domain securely reachable from authorized Tailscale clients without exposing applications to the public Internet or creating a second application-routing authority.

---

# Part II — Verified Repository State + Concrete Plan of Attack (rev. 3)

> Added after reviewing the design below against **live repo state** (`origin/main`,
> 2026-07-28), then revised (**rev. 3**) to fold in two independent-review passes. This section
> resolves every `<verified>` placeholder and turns the conceptual design into a
> concrete, wired implementation. Sections 0–22 are synchronized with this concrete
> plan where they contain executable workflow or operator-runbook instructions.

## II.0 Independent-review evaluation (rev. 3)

All findings are accepted. Finding #4 was only partially accepted in rev. 2; rev. 3
fully accepts it because AGENTS.md explicitly requires adding a guarded recipe when a
needed live operation has none.

| # | Finding | Verdict | Fix applied |
|---|---|---|---|
| 1 | `hostname` invalid with `replicas > 1`; use `hostnamePrefix` | **Accept** (verified in `v1.98.9` `api.md`) | Connector uses `hostnamePrefix`; validator requires it and rejects `hostname` |
| 2 | `tag:lab-router` ownership must precede device creation | **Accept** | ACL `tagOwners`/grants applied **before** the Connector reconciles (staging) |
| 3 | HA needs both-device approval + node spread (no default topology spread) | **Accept** | add a Connector `ProxyClass` with an explicit pod label + matching hard topology-spread selector; Kubernetes verifies `ConnectorReady`, two status devices, and two Ready pods on distinct nodes, while the operator verifies per-device route approval |
| 4 | Stage `suspend:true`, use guarded bootstrap, then activate | **Accept** | add `just bootstrap tailscale-subnet-router`; bootstrap and human acceptance occur from merged suspended source before the activation PR |
| 5 | `/32` overlaps home `/24` → hairpin while on-LAN | **Accept** | keep `/32` (least-privilege) but document + test the overlap behavior |
| 6 | Verify resolver/route selection, not just end result | **Accept** | client probe adds `scutil --dns`/`tailscale dns status` + `route -n get 192.168.90.30` |
| 7 | Worktree not clean → hand back | **Accept** | operator explicitly authorized fetching `origin/main` and preparing `feat/tailscale-lab-domain` in the existing slot; branch preparation completed with the plan preserved |

Rev. 3 also closes the follow-up review points:

- the ProxyClass constraint includes a pod label and matching `labelSelector`; no
  automatic `ScheduleAnyway` downgrade;
- Kubernetes verification does not claim to prove Admin Console approval;
- the retained runbook and PR sequence match Part II;
- `autogroup:member` is explicitly scoped to the current single-user tailnet and must
  be replaced with a dedicated group before onboarding additional users.

## II.1 Decision-gate outcome — **Decision C**

The repo runs the Tailscale operator (chart `1.98.9`, ns `tailscale`) with an HA
`ProxyGroup (type: ingress)` used for **per-service L7 Ingress** (only ntfy today).
There is **no** `Connector`/subnet router and **no** Tailscale-fronted shared Gateway.
So neither Decision A nor B applies → **Decision C**: split DNS + a narrowly-routed,
Operator-managed **Connector** pointing tailnet clients at the existing Pi-hole
resolver and Envoy Gateway VIP. The design doc's preferred architecture is sound.

## II.2 Verified network facts (placeholders resolved)

| Fact | Value | Source |
|---|---|---|
| Internal Envoy Gateway VIP | **`192.168.90.30`** :443 (MetalLB pool `internal` `.30–.39`, `autoAssign:false`) | `kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml`, `metallb/config/address-pool.yaml` |
| DNS resolver | **Pi-hole v6 `192.168.90.2`** :53 (`https://pi.hole`) | `kubernetes/apps/networking/external-dns/app/values.yaml` |
| DNS record model | **individual per-hostname A → `192.168.90.30`** (no wildcard record), `external-dns.k8s.io/audience=internal` filtered, `policy: upsert-only` | external-dns values |
| Wildcard TLS | real **LE production** cert, DNS-01 Cloudflare, secret `wildcard-lab-supermorphic-com-tls` | `kubernetes/apps/security/cert-manager/certificate/*` |
| Route attachment | namespace label `gateway.supermorphic.com/access: internal` + `parentRef` → Gateway `internal`/`networking` | `internal-gateway/app/gateway.yaml` |
| Pod / Service CIDR (**never advertise**) | `10.244.0.0/16` / `10.96.0.0/12`; LAN `192.168.90.0/24` | `clusterconfig/nuc*.yaml`, `talos/talconfig.yaml` |
| Operator | chart `1.98.9`, ns `tailscale`, OAuth Secret `operator-oauth` (SOPS) | `tailscale-operator/app/*` |
| Tags in use | `tag:k8s-operator` (owns), `tag:k8s`, `tag:ntfy` | `docs/tailscale-operator.md` |

Because Pi-hole already answers the zone with per-hostname A records → `192.168.90.30`,
**no DNS record changes are required**; a new `foo.lab.supermorphic.com` becomes
remotely usable for free once its normal HTTPRoute (with `audience=internal`) exists.

## II.3 Connector CRD facts (§6.3 HA + finding #1)

Verified against `v1.98.9` `k8s-operator/api.md`:
- `spec.replicas` enables HA subnet routers → run **`replicas: 2`** (not a single router).
- **`hostname` "should only be used … [with] a single replica"** → for `replicas > 1`
  use **`hostnamePrefix`** (each replica appends its ordinal). Using `hostname` with
  `replicas: 2` is wrong (finding #1).
- Tailscale applies **no default node affinity / topology spread**, so two replicas can
  co-locate on one Talos node → attach a **`ProxyClass`** with node-level spread (finding #3).
- `ProxyGroup` is **not** a subnet-router option (`spec.type` ∈ `ingress`/`egress`/`kube-apiserver`).

## II.4 Traffic path

```text
tailnet client
  → split-DNS query lab.supermorphic.com → Pi-hole 192.168.90.2 (via Connector /32 route)
  → A 192.168.90.30
  → HTTPS → Envoy Gateway VIP 192.168.90.30 (via Connector /32 route)
  → existing HTTPRoute + wildcard TLS (unchanged)
```

## II.5 Delivery decisions (revised by finding #4)

- **Staged rollout** (was single-PR): PR A ships infra `suspend:true` + validation +
  guarded bootstrap + verify + docs; the operator preconfigures ACL, performs the guarded
  rollout, approves routes, and completes client acceptance; only then does PR B flip
  `suspend:false` to activate durably.
- **Manual route approval** on both replicas; `autoApprovers` is deferred to a later
  hardening change.

## II.6 Branch / worktree pre-req (finding #7)

The operator explicitly authorized resolving the reusable slot. The same worktree was
fetched and moved from merged `chore/alertmanager-ntfy-activate` onto fresh
`origin/main` as `feat/tailscale-lab-domain`, preserving this plan. Before implementation:

```bash
git branch --show-current                 # must be feat/tailscale-lab-domain
git merge-base --is-ancestor origin/main HEAD
git add plans/tailscale-lab-supermorphic-domain-agent-plan.md
```

## II.7 Concrete changes

### 1. Connector + ProxyClass — co-located with the operator (mirrors `proxygroup/`)

New dir `kubernetes/apps/networking/tailscale-operator/subnet-router/`:

- `connector.yaml` — `tailscale.com/v1alpha1 Connector`, name `lab-subnet-router`:
  ```yaml
  spec:
    hostnamePrefix: lab-subnet-router   # NOT `hostname` — required for replicas > 1 (finding #1)
    replicas: 2                          # HA (finding #3)
    proxyClass: lab-subnet-router        # node spreading (finding #3)
    tags:
      - tag:lab-router                   # owned by tag:k8s-operator — ACL must precede reconcile (#2)
    subnetRouter:
      advertiseRoutes:
        - 192.168.90.2/32                # Pi-hole resolver
        - 192.168.90.30/32               # Envoy internal Gateway VIP
  ```
  IP literals carry inline comments, consistent with `envoyproxy.yaml` pinning `.30`.
- `proxyclass.yaml` — `tailscale.com/v1alpha1 ProxyClass` `lab-subnet-router`. Add a
  unique pod label and make the hard spread constraint select that exact label:
  ```yaml
  apiVersion: tailscale.com/v1alpha1
  kind: ProxyClass
  metadata:
    name: lab-subnet-router
  spec:
    statefulSet:
      pod:
        labels:
          tailscale.supermorphic.com/component: lab-subnet-router
        topologySpreadConstraints:
          - labelSelector:
              matchLabels:
                tailscale.supermorphic.com/component: lab-subnet-router
            maxSkew: 1
            topologyKey: kubernetes.io/hostname
            whenUnsatisfiable: DoNotSchedule
  ```
  The pod must match its own selector or Kubernetes will not count it correctly when
  calculating skew. Do **not** silently weaken this to `ScheduleAnyway`; if two replicas
  cannot schedule on distinct nodes, stop and hand the availability decision to the
  operator.
- `kustomization.yaml` — `resources: [./proxyclass.yaml, ./connector.yaml]`.

### 2. Flux Kustomization — staged, CRD-ordering split (findings #2, #4)

Append a `tailscale-operator-subnet-router` Kustomization to
`kubernetes/apps/networking/tailscale-operator/ks.yaml`, mirroring the existing
`tailscale-operator-proxygroup` doc but **`suspend: true`** initially:
`dependsOn: [tailscale-operator]` (the Connector is a `tailscale.com` CRD and must not
share the operator's atomic dry-run), `path: .../subnet-router`, `wait: true`. Staging
keeps the Connector from creating tailnet devices until the operator has added
`tag:lab-router` ownership. A guarded bootstrap deploys and verifies the suspended
source before activation. Activation is a separate flip-to-`suspend:false` PR (ntfy
#137 precedent). No change to `networking/kustomization.yaml`.

### 3. Static validation — bash, matching the tailscale convention (no chainsaw)

- `scripts/validate/tailscale-subnet-router.sh` — model on
  `scripts/validate/tailscale-operator.sh`:
  - all sources exist; `ks.yaml` still registered in `networking/kustomization.yaml`.
  - the `tailscale-operator-subnet-router` Kustomization `dependsOn: tailscale-operator`,
    points at the `subnet-router` path, and has a valid `suspend` bool.
  - Connector: **`hostnamePrefix` set and `hostname` absent** (finding #1);
    `spec.replicas >= 2`; `tags` contains `tag:lab-router`; `proxyClass: lab-subnet-router`.
  - **least-privilege gate (security-critical):** `advertiseRoutes` equals exactly
    `192.168.90.2/32` + `192.168.90.30/32`; hard-**refuse** any route containing `/24`,
    the Pod CIDR `10.244.`, the Service CIDR `10.96.`, or any non-`/32` mask.
  - ProxyClass has the exact pod label + matching `labelSelector`, `maxSkew: 1`,
    `topologyKey: kubernetes.io/hostname`, and `whenUnsatisfiable: DoNotSchedule`.
  - refuse any `Funnel`/`funnel` reference; `kustomize build subnet-router` renders.
- Register recipe `tailscale-subnet-router-validate: require-bash` in
  `kubernetes/mod.just`; add `validation.tailscale-subnet-router` to **both** the
  `suites:` list and the `executions.ci:` list in `tests/catalog.yaml` (right after
  `validation.tailscale-operator`, mirroring its metadata block).

### 4. Guarded bootstrap (operator-only; finding #4)

- Add `tailscale-subnet-router` to `.just/bootstrap.just`, mirroring the guarded ntfy
  and Tailscale Operator rollout structure:
  - confirmation:
    `TAILSCALE_SUBNET_ROUTER_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-subnet-router'`;
  - `require_deployed_source` covers `.just/bootstrap.just`, `kubernetes/mod.just`,
    `kubernetes/apps/networking/kustomization.yaml`,
    `kubernetes/apps/networking/tailscale-operator/ks.yaml`, and the complete
    `tailscale-operator/subnet-router/` source;
  - require the Git and live `tailscale-operator-subnet-router` Kustomizations to be
    suspended before rollout;
  - run `just kube tailscale-subnet-router-validate`;
  - reconcile the published Flux source and `cluster-apps`, resume/reconcile only
    `tailscale-operator-subnet-router`, wait for it to become Ready, and run
    `just kube tailscale-subnet-router-verify`;
  - on failure, re-suspend the Kustomization while preserving resources;
  - on success, instruct the operator to approve both routes on both devices, configure
    split DNS, complete client acceptance, and only then open the activation PR.

### 5. Read-only live verification (operator-only, excluded from `just ci`; findings #3, #6)

- `scripts/verify/tailscale-subnet-router.sh` asserts: Connector `Ready`/
  `ConnectorReady=True`; **`.status.devices` has 2** entries; the Connector StatefulSet
  has **2 ready replicas on 2 distinct nodes**; the Connector-wide spec/status reports
  exactly the two `/32` routes; Gateway `internal` Programmed; a representative HTTPRoute
  (e.g. `homepage`) Accepted; Pi-hole reachable. The identical Connector spec configures
  both replicas, but Kubernetes status does **not** prove per-device route approval.
  Print a **MANUAL** block: confirm both routes are advertised and approve both `/32`s
  on **both** `lab-subnet-router-*` machines; configure split DNS; run the client probe
  (§II.9).
  Register `verification.tailscale-subnet-router` in `tests/catalog.yaml` (human owner,
  `mutates_cluster: false`) + `tailscale-subnet-router-verify` recipe wrapping it via
  `run-catalog-suite.sh` (mirror `ntfy-verify`).

### 6. Documentation

- New `docs/tailscale-lab-domain.md` — operator runbook:
  - **ACL-first ordering** (finding #2): add `tagOwners`/grants **before** activation.
  - approve both `/32`s on **both** replica machines (finding #3).
  - split DNS: custom nameserver `192.168.90.2`, **Restrict to search domain**
    `lab.supermorphic.com`, keep MagicDNS.
  - **overlapping-subnet note** (finding #5): with accept-routes a `/32` outweighs the
    local `/24`, so a Tailscale-connected client **at home** hairpins Pi-hole/Gateway
    through the Connector; keep `/32` (least-privilege) but document + test, and note that
    home access to those two IPs then depends on Connector availability.
  - client acceptance (finding #6): `scutil --dns`/`tailscale dns status`,
    `route -n get 192.168.90.30`, `dscacheutil`, trusted `curl -I`, Tailscale-off negative.
  - Pi-hole→Technitium migration; Gateway-VIP-change coupling; shared-IP L4 limitation
    (a member reaching seerr can reach grafana — app auth still matters); DNS-rebinding note.
- Update the ACL policy block in `docs/tailscale-operator.md` (and
  `docs/tailscale-single-user-setup.md`): add `tagOwners` `tag:lab-router` (owned by
  `tag:k8s-operator`); `grants` for `autogroup:member` → `192.168.90.2/32` `tcp/udp:53`
  and → `192.168.90.30/32` `tcp:443`. This is intentional only for the current
  single-user tailnet. Before adding another user, replace `autogroup:member` with a
  dedicated group whose membership is explicitly reviewed. Flag `autoApprovers` as a
  **deferred** follow-up.

## II.8 Sequence (agent stops at each PR; operator gates)

1. **PR A — infra (`suspend:true`) + guarded bootstrap + validation + verify + docs.**
   `just ci` green.
2. **Operator gate:** apply ACL `tagOwners.tag:lab-router` + grants in the Admin Console
   (**before** bootstrap — finding #2). The OAuth client already carries
   `tag:k8s-operator`, which will own `tag:lab-router`, so no OAuth-client change is
   needed (same model as `tag:ntfy`).
3. **Operator guarded rollout:** from the clean merged PR A source, run:
   ```bash
   TAILSCALE_SUBNET_ROUTER_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-subnet-router' \
   mise exec -- just bootstrap tailscale-subnet-router
   ```
4. **Operator acceptance gate:** confirm 2 devices/pods on distinct nodes; approve both
   `/32`s on **both** machines; configure split DNS; run MacBook + iPhone acceptance,
   including the off-LAN negative test and the on-LAN overlap test.
5. **PR B — durable activation:** only after acceptance passes, flip the Kustomization
   to `suspend: false`; rerun `just ci`, merge, and run the read-only verification again.

## II.9 Verification

- **Offline (agent, gating):** `mise exec -- just ci` must pass — it now runs
  `validation.tailscale-subnet-router` (hostnamePrefix-not-hostname, dependency split,
  least-privilege route allowlist, ProxyClass spread, render) alongside `kubeconform`
  (Connector schema skipped-not-failed via `-ignore-missing-schemas`; correctness enforced
  by the bash validator) and every existing per-app validate.
- **Staged live rollout (operator, after PR A):** guarded bootstrap, followed by route
  approval, split-DNS configuration, and client acceptance off-LAN:
  ```bash
  scutil --dns | grep -A2 lab.supermorphic.com   # or: tailscale dns status
  route -n get 192.168.90.30                       # route selection via Connector
  dscacheutil -q host -a name homepage.lab.supermorphic.com   # → 192.168.90.30
  curl -I https://homepage.lab.supermorphic.com    # valid TLS, no -k
  # then disconnect Tailscale off-LAN ⇒ unreachable (negative test)
  ```
- **Durable live verification (operator, after PR B):**
  `mise exec -- just kube tailscale-subnet-router-verify`, then repeat a representative
  DNS + HTTPS client probe.

## II.10 Risks / watch-items

- **CRD schema** (finding #1): the `v1.98.9` CRD CEL-enforces that `hostname` cannot be
  specified with `replicas > 1`; the bash validator additionally requires
  `hostnamePrefix`.
- **Node spread** (finding #3): confirm the 2 replicas land on distinct Talos nodes; else
  stop rather than silently downgrade the hard availability constraint.
- **Egress path:** confirm no cluster-wide default-deny CNP blocks the `tailscale`
  namespace from reaching `192.168.90.2` / `192.168.90.30` on the LAN (ntfy uses per-ns
  CNPs; tailscale ns appears unrestricted — verify at rollout).
- **Hairpin to MetalLB VIP:** the subnet-router pod forwarding to the cluster's own
  `192.168.90.30` L2 VIP with Envoy `externalTrafficPolicy: Local` — expected to work;
  confirm during operator verify; fallback is a routing note in troubleshooting.
- **Overlapping /32 at home** (finding #5): document + test; reinforces HA/node-spread need.
- **DNS rebinding:** private A answer for a public-looking domain — documented as a
  troubleshooting item.
- Security-review answers all satisfied by design: no public reachability, no Funnel,
  no VLAN/Pod/Service CIDR advertised, OAuth SOPS-managed, app auth retained, off-LAN
  disconnect removes access.

---

# 0. Agent Operating Contract

Treat this document as implementation instructions for a coding agent working in the repository.

## Non-negotiable rules

1. **Git + Flux remain authoritative for Kubernetes desired state.**
2. **Envoy Gateway / Gateway API remain authoritative for HTTP routing.**
3. **Do not create per-application Tailscale proxies** if the existing shared Gateway can be reached securely over Tailscale.
4. **Do not expose the entire LAN or Kubernetes Pod/Service CIDRs** merely to make the wildcard domain work.
5. Route only the minimum IPs/CIDRs required.
6. `*.lab.supermorphic.com` must remain private.
7. Do not use Tailscale Funnel.
8. Do not publish private application endpoints to the public Internet.
9. Tailscale access control must be enforced with grants/ACLs, not only application authentication.
10. Do not commit OAuth client secrets, auth keys, API tokens, or DNS credentials in plaintext.
11. Reuse the existing Tailscale Operator, SOPS, Gateway API, DNS, validation, and test conventions in the repository.
12. Inspect the existing `ntfy` Tailscale implementation before designing new resources.
13. Do not assume an existing object name, namespace, Gateway address, Pi-hole IP, or tag is correct until verified in repository/live-read-only state.
14. Any change required in the Tailscale Admin Console must be documented as a human operator step unless there is already a supported repository-managed API workflow.
15. Prefer narrow `/32` routes for the DNS resolver and Gateway VIP over advertising `192.168.90.0/24`.

---

# 1. Desired User Experience

When an authorized device is connected to Tailscale:

```text
https://homepage.lab.supermorphic.com
https://grafana.lab.supermorphic.com
https://portainer.lab.supermorphic.com
https://seerr.lab.supermorphic.com
https://plex.lab.supermorphic.com
https://sonarr.lab.supermorphic.com
https://radarr.lab.supermorphic.com
https://prowlarr.lab.supermorphic.com
https://ntfy.lab.supermorphic.com
...
```

must resolve and work exactly as they do from the home LAN.

No per-application Tailscale hostname should be required.

The client should use:

```text
*.lab.supermorphic.com
```

everywhere.

---

# 2. Recommended Architecture

## 2.1 Preferred design: split DNS + narrowly routed existing Gateway

Reuse the existing LAN-facing Gateway and internal DNS.

```text
                      TAILSCALE CLIENT
                           iPhone
                             |
                             | DNS query:
                             | grafana.lab.supermorphic.com
                             v
                     Tailscale split DNS
                             |
                             v
                 Internal Pi-hole / Technitium
                             |
                             | returns existing
                             | Envoy Gateway VIP
                             v
                    Envoy Gateway / Gateway API
                             |
                +------------+-------------+
                |            |             |
             Grafana      Homepage       Seerr
                |            |             |
                +------------+-------------+
                             |
                          cluster
```

Tailscale provides the private network path to:

1. the internal DNS resolver; and
2. the existing Envoy Gateway VIP.

The Gateway continues to terminate TLS and route by hostname.

### Why this is preferred

- Existing `HTTPRoute` resources remain unchanged.
- Existing wildcard/custom TLS remains unchanged.
- Adding a new `*.lab.supermorphic.com` app automatically becomes reachable remotely once normal DNS/Gateway configuration exists.
- No one-proxy-per-application pattern.
- No second set of Tailscale-specific hostnames.
- LAN and tailnet users use the same URLs.
- Flux remains the only Kubernetes application configuration authority.

Tailscale supports restricted nameservers (split DNS) for a custom domain. A private nameserver may be reached through a subnet route. The Kubernetes Operator also supports subnet routers through the `Connector` CRD.

---

# 3. Architecture Decision Gate

Before writing manifests, inspect the repository and determine which design already exists for `ntfy`.

## Decision A — existing subnet-router/Connector pattern exists

If the repository already has an Operator-managed `Connector` or subnet-router mechanism that is appropriate:

**Reuse it.**

Add only the required routes.

Preferred:

```text
<DNS_RESOLVER_IP>/32
<ENVOY_GATEWAY_VIP>/32
```

Do not advertise the entire Servers VLAN unless a separate approved requirement exists.

## Decision B — existing Tailscale Gateway/ProxyGroup architecture already exposes the shared Envoy Gateway

If the repository already implements the official custom-domain Gateway API pattern using a Tailscale-backed `LoadBalancer`/Gateway and it is clearly the established architecture:

Reuse that instead of introducing a subnet router.

The agent must document why it is consistent with the current repo.

## Decision C — neither exists

Default to **split DNS + narrow routes through an Operator-managed Connector**.

Do not introduce a second Envoy Gateway unless required.

---

# 4. Repository Discovery

Before implementation, inspect:

```text
kubernetes/
  ...tailscale...
  ...gateway...
  ...external-dns...
  ...pihole/technitium...
  ...ntfy...

tests/
scripts/
docs/
plans/
Justfiles
mise.toml
```

Find:

- Tailscale Kubernetes Operator HelmRelease/version.
- Operator namespace.
- OAuth Secret/SOPS mechanism.
- current Tailscale tags.
- existing `ProxyGroup`, `ProxyClass`, `Connector`, Ingress, or Tailscale LoadBalancer resources.
- current `ntfy` tailnet exposure.
- Envoy Gateway implementation.
- GatewayClass(es).
- current internal Gateway VIP.
- existing wildcard certificate handling for `*.lab.supermorphic.com`.
- current DNS owner for `lab.supermorphic.com`.
- Pi-hole IP/current DNS architecture.
- future Technitium migration documentation.
- ExternalDNS behavior, if present.
- existing Tailscale access grants/ACL documentation.
- existing Tailscale operator verification/tests.
- human startup/runbook documentation conventions.

**Do not implement until the current architecture is understood.**

---

# 5. Required Network Facts

The implementation must determine and record:

```text
DNS resolver:
  current service: Pi-hole or Technitium
  address: <verified>
  UDP/TCP port: 53

Envoy Gateway:
  VIP/address: <verified>
  HTTPS port: 443
  HTTP port: 80 if redirect is intentionally supported

Domain:
  lab.supermorphic.com
  wildcard TLS: <verified>
  internal wildcard/individual DNS behavior: <verified>
```

If DNS currently uses:

```text
*.lab.supermorphic.com -> <Gateway VIP>
```

preserve that behavior.

If it uses individual records, do not unnecessarily replace them with a wildcard; simply ensure the restricted DNS resolver can answer the zone.

---

# 6. Tailscale Subnet Routing

## 6.1 Route only what is required

The ideal route advertisement is:

```text
<DNS_RESOLVER_IP>/32
<GATEWAY_VIP>/32
```

Example only:

```text
192.168.90.2/32
192.168.90.X/32
```

Do **not** copy example addresses without repository verification.

Avoid:

```text
192.168.90.0/24
10.244.0.0/16
10.96.0.0/12
```

unless separately required.

There is no need for the iPhone to directly address Pod IPs or ClusterIPs to use the application domain.

## 6.2 Operator-managed Connector

If using the Tailscale Kubernetes Operator, prefer its `Connector` CRD rather than adding an unmanaged Tailscale container.

Conceptual shape only:

```yaml
apiVersion: tailscale.com/v1alpha1
kind: Connector
metadata:
  name: lab-subnet
  namespace: <tailscale-namespace>
spec:
  subnetRouter:
    advertiseRoutes:
      - <DNS_RESOLVER_IP>/32
      - <GATEWAY_VIP>/32
  tags:
    - tag:<approved-router-tag>
```

**The agent must use the schema supported by the pinned Operator version, not this conceptual example.**

## 6.3 Availability

Determine whether the current Operator/Connector architecture provides adequate availability.

Because `*.lab.supermorphic.com` becomes the primary remote application entry point, avoid a single fragile unmanaged router.

If the established architecture has HA subnet routers, use that convention.

Do not invent an HA pattern unsupported by the pinned Operator.

---

# 7. Tailscale Split DNS

This is a required human/operator configuration unless the repository already manages tailnet DNS settings via an approved API workflow.

Configure a **restricted nameserver**:

```text
Nameserver:
<DNS_RESOLVER_IP>

Restrict to search domain:
lab.supermorphic.com
```

Do **not** configure the internal DNS server as a global resolver merely for this project.

Desired behavior:

```text
grafana.lab.supermorphic.com
  -> private DNS resolver

google.com
  -> normal client/global DNS path
```

MagicDNS may remain enabled.

`lab.supermorphic.com` split DNS and MagicDNS are complementary.

## DNS reachability dependency

The restricted DNS resolver must be reachable through the tailnet.

Therefore:

```text
DNS split configuration
        +
route to DNS resolver
```

are both required.

---

# 8. Tailscale Access Control

Access must be intentional.

## 8.1 Suggested identity model

Reuse existing tags if already standardized.

Conceptual roles:

```text
tag:k8s-operator
tag:k8s
tag:lab-ingress
tag:lab-dns
tag:ntfy
```

Do not add tags merely for aesthetics.

## 8.2 Human/admin devices

The operator's trusted devices may access:

```text
DNS resolver:
  UDP 53
  TCP 53

Envoy Gateway:
  TCP 443
  optionally TCP 80 only for HTTPS redirect
```

No direct access to the full LAN is required for this feature.

## 8.3 Family/non-admin clients

If additional users/devices eventually use Seerr/Plex remotely, do not automatically grant them the same infrastructure access as admin devices.

Prefer a separate policy scope.

The concrete `autogroup:member` grants in Part II are acceptable only because the
current tailnet is intentionally single-user. Before onboarding any additional user,
replace them with a dedicated group and explicitly review that group's membership.

Note: because all applications share the same Gateway IP and TCP/443, **Tailscale L3/L4 grants alone cannot distinguish `grafana.lab...` from `seerr.lab...` when they share one destination IP/port.**

Application-level authentication remains important.

If strong per-application network authorization is later required, evaluate Tailscale L7 ingress or separate proxy identities rather than pretending a shared-IP ACL provides hostname-level isolation.

This limitation must be documented.

---

# 9. Gateway / TLS

The existing Gateway remains authoritative.

Verify:

- `*.lab.supermorphic.com` certificate is valid from Tailscale clients.
- Gateway listener accepts the relevant hostnames.
- HTTPRoutes remain attached and `Accepted`.
- no Tailscale-specific insecure TLS bypass is required.
- no client should use `http://<IP>:port` as the normal access path.

Desired:

```text
https://grafana.lab.supermorphic.com
```

not:

```text
http://192.168.x.x
http://100.x.x.x
https://foo.ts.net
```

unless troubleshooting.

---

# 10. DNS Migration Compatibility

The current environment may use Pi-hole while Technitium DNS is planned.

Do not couple Tailscale clients permanently to a deprecated DNS layout without documenting migration.

Design the implementation so the future migration is:

```text
Pi-hole DNS IP
      ->
Technitium DNS IP(s)
```

with minimal changes.

If Technitium will have two resolvers, plan for two restricted nameservers when deployed.

Do not prematurely deploy Technitium as part of this change.

---

# 11. Validation Policy

Extend repository validation to enforce the architecture where practical.

Suggested checks:

- Connector/subnet route does not advertise Pod CIDR.
- does not advertise Service CIDR.
- does not advertise full Servers VLAN unless explicitly allowlisted.
- expected DNS resolver `/32` exists.
- expected Gateway VIP `/32` exists.
- no Funnel resource/configuration.
- no public LoadBalancer introduced for this feature.
- Tailscale OAuth credentials remain Secret/SOPS-managed.
- no Tailscale auth key embedded in manifests.
- Gateway/HTTPRoutes are not duplicated solely for tailnet access.
- route/tag names follow repository conventions.

If IP addresses are intentionally configuration data in Git, centralize them using the repo's established pattern rather than duplicating literals.

---

# 12. Read-only Verification

Add a guarded verification that proves:

1. Operator/Connector resource Ready.
2. advertised routes match intended values.
3. Gateway remains Ready/Programmed.
4. representative HTTPRoutes remain Accepted.
5. DNS resolver is healthy from inside the LAN/cluster.

The local CI environment must not pretend to validate Tailscale Admin Console state if it cannot access it.

Separate:

```text
offline/static validation
```

from:

```text
operator tailnet acceptance
```

honestly.

---

# 13. Chainsaw Smoke Coverage

Add a read-only platform smoke scenario if it matches the repository's current test taxonomy.

Suggested logical scenario:

```text
just test smoke platform tailscale-lab-domain
```

or the current approved equivalent.

Chainsaw may assert:

- Tailscale Operator Ready.
- Connector/route resource exists and Ready.
- expected advertised routes in spec.
- Envoy Gateway Programmed.
- representative HTTPRoutes Accepted.
- required Services exist.

Chainsaw running inside the cluster cannot prove an iPhone's split-DNS behavior.

Do not mislabel Kubernetes structural assertions as client E2E proof.

---

# 14. Tailnet E2E Acceptance Probe

Create or document an operator-side probe that runs from a real Tailscale client.

Prefer MacBook for command-line acceptance.

For representative names:

```text
homepage.lab.supermorphic.com
grafana.lab.supermorphic.com
portainer.lab.supermorphic.com
seerr.lab.supermorphic.com
ntfy.lab.supermorphic.com
```

Validate:

## DNS

On macOS use OS-native resolution:

```bash
scutil --dns
# or, when supported by the installed client:
tailscale dns status
dscacheutil -q host -a name homepage.lab.supermorphic.com
```

Do not rely solely on `nslookup` for split-DNS validation.

Confirm that `lab.supermorphic.com` is assigned to nameserver `192.168.90.2`.
The `dscacheutil` answer must contain `192.168.90.30`.

## Route selection

Off-LAN, confirm the Gateway `/32` is routed through Tailscale:

```bash
route -n get 192.168.90.30
```

The output must show a Tailscale-managed interface/path rather than an unrelated local
or default route.

## HTTPS

```bash
curl -I https://homepage.lab.supermorphic.com
```

Require:

- DNS success.
- TCP success.
- TLS validation success.
- expected HTTP status/redirect.

Do not use `curl -k`.

## Negative

Disconnect Tailscale while off-LAN and confirm the private host is no longer reachable.

The public Internet must not become the fallback route.

---

# 15. Human Operator Runbook

## 15.1 Preflight before PR A and guarded bootstrap

Confirm:

- Tailscale client installed on MacBook/iPhone.
- current operator access to the Tailscale Admin Console.
- current internal domain works from home LAN.
- Gateway TLS is valid.
- Tailscale Operator already healthy.
- route target IPs are verified.
- before guarded bootstrap, `tag:lab-router` is owned by `tag:k8s-operator` and the
  intended DNS/Gateway grants are saved in the tailnet policy.

## 15.2 Tailscale Admin Console — route approval

After Flux deploys the subnet router/Connector:

1. Open **Tailscale Admin Console → Machines**.
2. Locate **both** `lab-subnet-router-*` replica devices.
3. For each replica, open **Edit route settings**.
4. On each replica, approve only:
   - `192.168.90.2/32` — DNS resolver
   - `192.168.90.30/32` — Gateway VIP
5. Confirm neither replica advertises an unexpected subnet.
6. Save both devices and confirm both remain connected.

If repository tailnet policy supports `autoApprovers` for these exact narrow routes, the agent may propose it, but it must be reviewed explicitly before replacing this manual approval.

## 15.3 Tailscale Admin Console — split DNS

1. Open **DNS**.
2. Keep MagicDNS enabled unless there is a separate reason not to.
3. Choose **Add nameserver → Custom**.
4. Enter the internal DNS resolver address.
5. Enable **Restrict to search domain**.
6. Enter:

```text
lab.supermorphic.com
```

7. Save.
8. Do **not** enable global DNS override as part of this feature unless separately intended.

## 15.4 Tailscale Admin Console — access policy

Configure and save the tailnet access policy/grants **before guarded bootstrap** so the
operator is already permitted to create devices tagged `tag:lab-router`.

Ensure authorized admin devices/users can reach:

```text
<DNS_RESOLVER_IP>:53 TCP/UDP
<GATEWAY_VIP>:443 TCP
```

Optionally:

```text
<GATEWAY_VIP>:80 TCP
```

if HTTP redirects to HTTPS are part of the Gateway design.

Do not grant the entire Servers VLAN solely for wildcard-domain access.

For the current single-user tailnet, `autogroup:member` is the intended source. Replace
it with a dedicated reviewed group before onboarding any additional user.

## 15.5 macOS verification

With Tailscale connected and the Mac off the home LAN if practical:

```bash
scutil --dns
# or: tailscale dns status
route -n get 192.168.90.30
dscacheutil -q host -a name homepage.lab.supermorphic.com
curl -I https://homepage.lab.supermorphic.com
curl -I https://grafana.lab.supermorphic.com
curl -I https://portainer.lab.supermorphic.com
```

Verify the restricted resolver is `192.168.90.2`, the Gateway `/32` uses the Tailscale
path, and the certificate chain validates normally.

Then disconnect Tailscale and confirm remote access fails.

Repeat a representative DNS + HTTPS request on the home LAN with Tailscale enabled.
Confirm the `/32` route hairpins through the Connector as documented and still succeeds.

## 15.6 iPhone verification

1. Install/open Tailscale.
2. Connect to the tailnet.
3. Confirm the device uses Tailscale DNS settings.
4. Disable Wi-Fi temporarily so the test uses cellular.
5. In Safari open:

```text
https://homepage.lab.supermorphic.com
```

6. From Homepage, open representative services.
7. Confirm:
   - no certificate warning;
   - no public exposure dependency;
   - Grafana/Portainer/Seerr authenticate normally;
   - ntfy continues operating as intended.
8. Turn Tailscale off while still on cellular.
9. Confirm the private `*.lab.supermorphic.com` services are unreachable.

This is the primary human acceptance test.

---

# 16. Startup / Recovery Documentation

Create/update operator documentation covering:

## Fresh Tailscale setup

- Tailscale Operator prerequisite.
- OAuth/SOPS setup pointer.
- route deployment.
- route approval.
- split DNS.
- grants.
- device acceptance.

## New client onboarding

For a new iPhone/iPad/Mac:

1. Install Tailscale.
2. authenticate to the approved tailnet.
3. ensure DNS settings are accepted.
4. test Homepage.
5. verify expected authorization scope.

Do not require per-application configuration.

## DNS resolver replacement

When Pi-hole is replaced by Technitium:

1. deploy/validate Technitium first;
2. verify `lab.supermorphic.com` records locally;
3. make Technitium reachable to tailnet;
4. add new restricted DNS server(s);
5. test tailnet resolution;
6. remove Pi-hole restricted resolver after validation;
7. remove obsolete route only after no clients depend on it.

## Gateway VIP change

If the Envoy Gateway VIP changes:

1. update authoritative internal DNS as normal;
2. update narrow Tailscale advertised route;
3. approve route if required;
4. validate from a tailnet client;
5. remove old route.

Document this coupling clearly.

---

# 17. Failure Modes and Troubleshooting

## DNS works on LAN but not on Tailscale

Check:

- client accepts Tailscale DNS;
- restricted domain exactly `lab.supermorphic.com`;
- route to DNS resolver exists;
- access grant permits TCP/UDP 53;
- DNS resolver allows requests from the routed/SNAT source;
- DNS rebinding protection is not rejecting the private-domain response.

## DNS resolves but HTTPS fails

Check:

- route to Gateway VIP;
- grant to TCP 443;
- Envoy Gateway listener;
- Gateway status;
- HTTPRoute status;
- TLS certificate;
- backend health.

## One app fails but others work

Tailscale routing and DNS are probably healthy.

Check that app's:

- HTTPRoute hostname;
- backend Service;
- authentication;
- application base URL/Host-header behavior.

## Works on Wi-Fi but not cellular

This is likely a Tailscale path/DNS issue rather than the app itself.

Validate on-device tailnet state and split DNS.

---

# 18. Security Review

Before completion, explicitly answer:

1. Can an unauthenticated Internet client reach the Gateway because of this change?
   - Required answer: **No**.
2. Is Funnel enabled?
   - Required answer: **No**.
3. Is the whole Servers VLAN advertised?
   - Preferred answer: **No**.
4. Are Pod/Service CIDRs advertised?
   - Required answer: **No**, unless covered by a separately approved design.
5. Are OAuth/auth-key secrets encrypted?
   - Required answer: **Yes**.
6. Can a non-admin tailnet user reach Grafana/Portainer merely because they can reach Seerr?
   - Document the shared-Gateway L4 policy limitation.
7. Does app authentication remain enabled?
   - Required answer: **Yes**.
8. Does disconnecting Tailscale off-LAN remove access?
   - Required answer: **Yes**.

---

# 19. PR and Operator-Gate Sequence

## PR A — staged routing infrastructure

- Connector + hard-spread ProxyClass;
- Flux Kustomization committed `suspend: true`;
- guarded `bootstrap tailscale-subnet-router` recipe;
- static validation and read-only live verification;
- complete operator/client runbook.

The agent runs `just ci`, opens the PR, and stops. The operator reviews and merges it.

## Operator gate — preconfigure, bootstrap, and accept

1. Add `tag:lab-router` ownership and the narrow grants.
2. Run the guarded bootstrap from clean, merged PR A source.
3. Confirm `ConnectorReady`, two status devices, and two Ready pods on distinct nodes.
4. Approve both `/32` routes on both replica devices.
5. Configure restricted split DNS.
6. Complete MacBook off-LAN, iPhone cellular, Tailscale-off negative, and home-LAN
   overlap acceptance.

Do not open the activation PR until this gate passes.

## PR B — durable activation

- flip only `tailscale-operator-subnet-router` to `suspend: false`;
- rerun `just ci`;
- open the activation PR;
- after the operator merges it, rerun the read-only live verification and a
  representative client probe.

## Optional later hardening

Only after the manual workflow is proven:

- auto-approval of the exact routes if justified;
- repeatable tailnet E2E probing;
- Grafana/Gatus visibility;
- alerting for route/proxy health.

---

# 20. Definition of Done

The feature is complete when all of the following are true:

- `*.lab.supermorphic.com` continues to work on the home LAN.
- An authorized Tailscale client can resolve the domain remotely.
- DNS queries for `lab.supermorphic.com` use the restricted private resolver.
- unrelated DNS queries are not forced through the homelab DNS server.
- tailnet routing exposes only the required DNS/Gateway addresses.
- both Connector replicas are Ready on distinct Talos nodes.
- both `/32` routes are approved on both Connector devices.
- the existing Envoy Gateway remains the application-routing authority.
- TLS validates normally for the custom domain.
- representative services work from MacBook over a non-LAN network.
- representative services work from iPhone over cellular.
- disconnecting Tailscale while off-LAN makes the private domain unreachable.
- no Funnel/public ingress was created.
- app authentication remains enabled.
- Tailscale credentials are SOPS-managed.
- static validation and Kubernetes smoke pass.
- guarded bootstrap and operator/client acceptance pass before durable activation.
- operator documentation covers route approval, split DNS, grants, new-device onboarding, DNS migration, Gateway-IP changes, and troubleshooting.

---

# 21. Agent Self-Evaluation

Before handoff, score each category 0–3:

- repository-pattern reuse
- least-privilege routing
- DNS correctness
- Gateway/TLS preservation
- tailnet access-control correctness
- secret management
- static validation
- test coverage
- operator documentation
- migration/recovery documentation

Completion rules:

- no category below 2;
- routing/security/secrets must score 3;
- explicitly list anything that remains operator-only;
- do not claim client E2E success unless an operator actually ran it.

The agent must state:

```text
Implemented:
...

Offline verified:
...

Requires human Tailscale console action:
...

Requires human client acceptance:
...

Deferred:
...
```

---

# 22. Upstream References

Implementation must verify behavior against the current docs for the pinned versions:

- Tailscale Kubernetes Operator:
  https://tailscale.com/docs/kubernetes-operator

- Operator subnet router / Connector:
  https://tailscale.com/docs/kubernetes-operator/connector/deploy-subnet-router

- Tailscale DNS:
  https://tailscale.com/docs/reference/dns-in-tailscale

- Tailscale subnet routers:
  https://tailscale.com/docs/features/subnet-routers

- Custom domains + Kubernetes Gateway API:
  https://tailscale.com/docs/solutions/kubernetes-operator-byod-gateway-api

---

# Final Architecture Principle

```text
Tailscale owns private remote connectivity.
Internal DNS owns `lab.supermorphic.com`.
Envoy Gateway owns HTTPS + hostname routing.
Flux/Git owns Kubernetes desired state.
Applications own their normal authentication.
```

Adding a new application beneath the existing Gateway should not require a new Tailscale integration.

Once the shared DNS + Gateway path is working, a new:

```text
foo.lab.supermorphic.com
```

should become remotely usable through the same architecture simply by following the normal GitOps DNS/Gateway application pattern.
