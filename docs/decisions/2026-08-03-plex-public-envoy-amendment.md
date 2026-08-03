# Plex public Envoy and split-horizon remote access — amendment

Status: Accepted (2026-08-03)
Amends [Plex Relay and Sonos integration — design](2026-08-02-plex-relay-sonos-design.md).
Date: 2026-08-03.
Branch: `investigate-plex-remote-access`.

This document is **additive**. It supersedes one decision in the 2026-08-02 design —
the selection of Plex Relay as the primary remote path — and the acceptance claims
that depended on it. Everything else in that document remains in force.

## 1. Decision

Publish Plex to the Internet through a **dedicated external Envoy Gateway** on a
single UniFi TCP 443 DNAT, using **split-horizon DNS on the existing hostname**
`plex.lab.supermorphic.com`. Retain Plex Relay as a best-effort fallback.

LAN clients continue to resolve the hostname privately through Pi-hole and reach the
existing internal Envoy Gateway. The Plex and Sonos cloud workflow resolves the same
hostname publicly through Cloudflare (DNS-only) to the residential WAN address, where
one DNAT rule forwards TCP 443 to a **dedicated** Envoy data plane that serves
exactly one hostname and routes to exactly one backend.

This is authorised as a **staged, operator-attended experiment**, not as a permanent
configuration. Permanence is a separate decision, taken only after a clean run.

### 1.1 What is superseded

| 2026-08-02 decision | Status |
|---|---|
| Plex Relay as the **primary** off-site path | **Superseded.** Relay is now a fallback |
| "Do not publish Plex through a UniFi WAN port forward" | **Superseded**, narrowly: one TCP 443 DNAT to a dedicated Envoy is authorised. Direct publication of Plex `32400` remains rejected |
| Acceptance claims resting on Relay sufficiency | **Superseded.** Relay does not satisfy the Sonos objective |

### 1.2 What is retained

The Relay identity repair (init-generated passwd, UID/GID `568`), pod and filesystem
hardening, read-only media, the Plex-owned Relay key cache, the containment analysis,
the rejection of Cloudflare Tunnel and Tailscale Funnel for media delivery, and Relay
itself as a fallback path. Section 6 of the original design stands unchanged.

Completed implementation history is not rewritten.

## 2. Goals and acceptance criteria

**Primary objective.** Sonos players appear in Plexamp and accept playback without
AirPlay.

**Non-negotiable constraint.** Local playback must not regress. Apple TV, Plex iOS,
Plexamp "This device", native Sonos-to-Plex, internal browser access, and in-cluster
integrations must continue to work through the existing internal paths.

Success requires the primary objective **and** no regression in any hard row of the
client acceptance matrix (section 12). The objective succeeding while a hard row
regresses is a failed experiment.

### Non-goals

- Permanent public exposure. That is a later, separate decision.
- Public IPv6. No AAAA record is published until IPv6 receives its own firewall design.
- Cloudflare proxy or Tunnel, Tailscale Funnel, or a VPS relay.
- Direct publication of Plex TCP `32400` to the Internet.
- Cluster-wide transparent encryption. See section 5.3.

## 3. Evidence that invalidated the Relay-first path

The 2026-08-02 design recorded that the custom server access URL did not prevent the
Relay experiment. Subsequent testing disproved that as a complete solution.

**With the custom access URL set to `https://plex.lab.supermorphic.com`:**

- Apple TV connects normally.
- Plex and Plexamp local clients use the internal Envoy path.
- Sonos devices appear after Plex/Sonos authorisation.
- Plexamp **cannot** switch playback to Sonos — "could not switch to player".
- Plex Web fails to switch to Sonos in the same way.

**With the custom access URL cleared:**

- Plexamp switches to Sonos and plays successfully.
- Plexamp "This device" falls back to Relay and reports Indirect.
- Apple TV cannot connect to Plex at all.
- A 4K Plex iOS session initially showed Indirect at 2 Mbps, transcoded to SD.
- A later 4K session showed the internal Envoy pod as source at roughly 96 Mbps with
  video and audio Direct Play. This is attributed to cached custom-URL discovery in
  Plex iOS and does **not** demonstrate that the cleared configuration is reliable.

**Conclusion.** Clearing the custom URL is rejected: it fixes Sonos at the cost of
Apple TV and forces Plexamp onto Relay. The hostname must remain advertised **and**
become reachable from the Plex and Sonos cloud workflow. Relay cannot satisfy this —
it has incomplete client support and a 2 Mbps ceiling.

### 3.1 Session classification is not a routing signal

Plex reports internally reverse-proxied sessions as **Remote** because it observes the
Envoy pod address, not the client's. This is classification, not Internet or Relay
routing. Plex's `LAN Networks` setting affects bandwidth classification only — not
routing and not authentication.

This has a direct consequence for testing: Plex's dashboard **cannot** be used to
determine which path a client took. See section 12.

## 4. Architecture

![Split-horizon data flow](images/2026-08-03-plex-split-horizon-data-flow.png)

Editable source: [`2026-08-03-plex-split-horizon-data-flow.svg`](images/2026-08-03-plex-split-horizon-data-flow.svg)

### 4.1 Private horizon — unchanged

```
plex.lab.supermorphic.com
  -> Pi-hole private answer
  -> existing internal Envoy Gateway (MetalLB VIP, pool `internal`)
  -> Service plex:32400
```

No internal DNS record, internal HTTPRoute, wildcard certificate, ClusterIP
integration, or VLAN rule is modified by this design.

### 4.2 Public horizon — new

```
plex.lab.supermorphic.com
  -> Cloudflare authoritative DNS, A record only, proxied=false, TTL 300
  -> current residential WAN IPv4 (dynamic, maintained by UniFi DDNS)
  -> one UniFi DNAT: WAN TCP 443 -> public VIP TCP 443
  -> dedicated external Envoy data plane (MetalLB pool `public`)
  -> exact-hostname HTTPS listener
  -> Plex-only HTTPRoute
  -> Service plex:32400
```

### 4.3 Isolation invariants

- WAN traffic is never forwarded to the shared internal Envoy.
- The external Envoy has its own GatewayClass, EnvoyProxy, Deployment, Service, VIP,
  listener, and certificate.
- No wildcard public route.
- No Envoy admin or control endpoint is exposed.
- No Cloudflare proxy or Tunnel; no Tailscale Tunnel or Funnel.
- No public IPv6 or AAAA.
- Relay remains enabled as a fallback.
- The public EnvoyProxy **mirrors the internal one** — replica count, resource requests,
  and PodDisruptionBudget — differing only in address pool and `loadBalancerIPs`,
  listener hostname, certificate reference, and `allowedRoutes`. The internal data plane
  is proven to carry Plex streaming, so any further divergence is a defect rather than a
  tuning opportunity.

## 5. TLS and certificate design

The public listener presents a **dedicated certificate for
`plex.lab.supermorphic.com` only**, issued by the existing `letsencrypt-production`
ClusterIssuer over the existing Cloudflare DNS-01 solver, into the
`networking-public` namespace.

### 5.1 Why not reuse the wildcard

The internal Gateway terminates with `wildcard-lab-supermorphic-com-tls`
(`*.lab.supermorphic.com`). Mounting that key into an Internet-facing pod would mean
that compromising the public Envoy yields a private key valid for **every** internal
hostname — Grafana, Prometheus, Alertmanager, Portainer, Longhorn, every `*arr`,
Seerr, and the test-report site. A dedicated data plane carrying the master key for
all internal services is not isolated in the sense that matters.

A second, separately-keyed wildcard was also rejected: different key material, but
identical impersonation authority.

### 5.2 Accepted cost

A non-wildcard certificate publishes `plex.lab.supermorphic.com` into Certificate
Transparency logs by exact name. Today only the wildcard appears there, so specific
hostnames are not enumerable from CT. This is a real new disclosure, and CT firehose
scanners probe newly-issued names promptly.

It is accepted because the name will carry a public A record regardless, `plex` is a
high-probability guess in any subdomain wordlist, and a residential address with an
open 443 is discovered by Internet-wide scanning independently of CT. Key isolation is
the substantive control; hostname obscurity is not.

### 5.3 Backend hop — plaintext, accepted

Envoy connects to `plex:32400` over plaintext HTTP, as the internal Gateway already
does. Cilium runs `routingMode: tunnel` with `tunnelProtocol: vxlan` and no
transparent encryption, so this hop crosses the node network unencrypted — the same
condition every other cluster service already accepts.

**BackendTLSPolicy is rejected.** Plex serves TLS on `32400` with a certificate for
`<hash>.<machine-id>.plex.direct`, where the hash derives from the server address and
the chain rotates on Plex's schedule. Validating it requires pinning an opaque,
externally-managed rotating name plus a CA bundle outside the operator's control. When
it rotates, Envoy fails validation and the public path breaks silently. That trades a
low-likelihood confidentiality risk for a moderate-likelihood availability risk on the
path whose entire purpose is reliability.

**Cilium transparent encryption (WireGuard) is the correct fix and is out of scope.**
It would address this hop generically for all services, but it is a cluster-wide CNI
change with MTU pressure stacked on VXLAN and throughput cost on high-bitrate direct
play. It requires its own design and is **not** a prerequisite for this experiment.

Residual risk is accepted and bounded: an attacker positioned to observe the node
network already holds a position that makes this hop the lesser problem.

## 6. Gateway isolation and trust boundaries

![Public Envoy trust boundaries](images/2026-08-03-plex-public-envoy-trust-boundaries.png)

Editable source: [`2026-08-03-plex-public-envoy-trust-boundaries.svg`](images/2026-08-03-plex-public-envoy-trust-boundaries.svg)

### 6.1 The controller watch scope is not additive

`kubernetes/apps/networking/envoy-gateway/app/values.yaml` restricts the controller:

```yaml
watch:
  type: NamespaceSelector
  namespaceSelector:
    matchLabels:
      gateway.supermorphic.com/access: internal
```

A Gateway in a new namespace is **invisible to the controller** — it does not
reconcile, does not provision a data plane, and does not surface an obvious error.
This design therefore requires widening the selector to a `matchExpressions` form
admitting both `internal` and `public`.

That edit lands on the **shared component every internal service depends on**. It is
the only change in this design capable of breaking the internal path on its own, and
it is staged as an independent, regression-gated step ahead of any public resource.

### 6.2 Isolation controls

| # | Control | Enforced by |
|---|---|---|
| 1 | Separate GatewayClass `public` with its own EnvoyProxy, Deployment, and Service | Envoy Gateway provisions infrastructure per Gateway |
| 2 | Listener hostname is exactly `plex.lab.supermorphic.com` | Gateway API hostname intersection: a route naming any **other** hostname cannot attach, and that much is specification-guaranteed. Its limit must be stated — a route that omits `hostnames` inherits the listener's, so this control constrains which hostname is served, not which backend serves it |
| 3 | `allowedRoutes.namespaces.from: Selector` on a new label `gateway.supermorphic.com/public-plex: "true"`, with `kinds: [HTTPRoute]` | Narrows admission to `media` alone instead of every namespace labelled `access: internal`. It does **not** isolate Plex *within* `media`: namespace selection cannot distinguish the Plex route from the Sonarr, Radarr, qBittorrent, Prowlarr, Seerr, Lidarr, and Tautulli routes beside it. All eight pin their own hostname today, so none attaches, but nothing structural prevents a future `media` route from attaching to the public Gateway and serving the Plex hostname to another backend |
| 4 | Dedicated MetalLB pool `public`, single address, `autoAssign: false`, explicit `loadBalancerIPs` | Gives UniFi a stable, unambiguous DNAT target that cannot drift onto another service |
| 5 | Service exposes 443/TCP only; Envoy admin remains on localhost | Envoy Gateway default, verified by negative test rather than assumed |
| 6 | UniFi DNAT names exactly WAN 443/TCP to the public VIP | Must not be a forward-to-LAN-any rule |
| 7 | CiliumNetworkPolicy on the Plex endpoint | Section 7 |

`media` carries both labels: `access: internal` for the controller watch and internal
Gateway, and `public-plex: "true"` for the public Gateway. `networking-public` carries
`access: public`.

### 6.3 Namespace placement as an enforced guard

The public Gateway lives in its own namespace, `networking-public`, rather than
alongside the internal Gateway in `networking`. A Gateway in `networking` can
reference the wildcard secret with no ReferenceGrant, so a later edit could silently
attach the wildcard key and nothing would object. From a separate namespace, that
reference requires an explicit cross-namespace ReferenceGrant that will not exist.

This converts an agreement into an API-level refusal, consistent with this
repository's preference for enforcement over instruction.

The Plex HTTPRoute remains in `media` alongside the application and attaches
cross-namespace through `allowedRoutes`. Its `backendRef` is same-namespace, so no
ReferenceGrant is required there.

### 6.4 Admission control is absent in `media`

The `media` namespace enforces Pod Security Admission `privileged`, required by
Gluetun's `NET_ADMIN` and Plex's `/dev/dri` access. Plex's non-root UID/GID `568`,
dropped capabilities, `RuntimeDefault` seccomp, and disabled service-account token are
therefore **manifest-declared, not admission-enforced**. A future manifest could run
Plex privileged and admission would not object.

Mitigation within this scope: a CI assertion pinning Plex's securityContext fields,
converting the invariant from convention into a gate. Relocating Plex to a
baseline-enforced namespace would be stronger and is out of scope for this experiment.

## 7. Network containment

A Plex-specific CiliumNetworkPolicy is a **hard prerequisite** before any public
ingress. This matches the original design's intent — "Plex-specific Cilium policy
after observed flow inventory" — and makes the sequencing binding.

### 7.1 The allow-list cannot be derived from Git

No manifest in `kubernetes/` references `plex:32400` except Homepage's widget
annotation on the Plex HTTPRoute itself. Tautulli's Plex URL lives in its
PersistentVolumeClaim configuration, not in the repository.

More significantly, **the path by which a Sonos player currently reaches Plex is not
established**. Native Sonos playback works today, but whether the player arrives via
the internal Envoy VIP, a `plex.direct` address, or another route is unknown. A policy
written on a guess breaks native Sonos playback — a local regression, which section 2
forbids.

**Prerequisite.** Before the policy is written, observe actual ingress to the Plex pod
with Hubble across a window containing an Apple TV session, a Plexamp session, a
**native Sonos session**, a Tautulli poll, a Homepage widget refresh, a Gatus probe,
and kubelet probes. The allow-list is derived from that capture and from nothing else.

### 7.2 Policy shape

Ingress to the Plex endpoint on `32400` is restricted to the observed consumer set.
Under Envoy Gateway's default deployment mode both data planes are provisioned into
the controller's namespace, so a namespace selector cannot distinguish the internal
proxy from the public one. The Gateway-owner pod label is used instead. The actual
placement is confirmed during phase 1 rather than assumed, and the pod-label approach
is correct under either deployment mode.

Egress is restricted to cluster DNS and to TCP 443 through Cilium's `world` entity.
What that does and does not mean must be stated precisely: `world` is **every endpoint
outside the cluster**, not a Plex-cloud selector. It permits TCP 443 to any off-cluster
host, including the NAS, the UniFi gateway, and any VLAN device listening on HTTPS. It
bounds protocol and port, not destination. This matches the existing cluster pattern —
the ntfy policy uses the same broad `world:443` rule, because the cluster has no
FQDN-egress baseline — and narrowing it remains an open question against this design.

The media share is mounted by the CSI driver on the node, not by the pod, so no SMB
egress rule is expected — this is confirmed during the capture rather than assumed.

## 8. Dynamic DNS

Xfinity provides a dynamic residential IPv4 address. UniFi observes the WAN lease
directly and supports Cloudflare DDNS natively. A Kubernetes ExternalDNS controller is
unsuitable: it would publish the private MetalLB VIP, not the residential address.

Design:

- UniFi-managed DDNS against Cloudflare authoritative DNS.
- Public **A record only**, `proxied=false`, TTL 300.
- Internal Pi-hole record unchanged.
- The existing `external-dns` deployment is Pi-hole-only, filtered to
  `gateway-name: internal` and `audience=internal`, with `policy: upsert-only`. It
  cannot and will not touch Cloudflare or the public record.

### 8.1 Credential design and preflight

**Hard gate.** The design requires proof that UniFi accepts a least-privilege
Cloudflare API token scoped to `Zone:DNS:Edit` on `supermorphic.com`. If UniFi
requires a Global API Key, the mechanism is rejected and the design returns to
brainstorming. A global key is never accepted merely to make DDNS work.

The DDNS token must be a **distinct credential** from cert-manager's existing
`cloudflare-api-token`. Same zone and permission class, separate tokens: a compromised
UniFi must not yield the credential that also issues certificates, and either can be
revoked without breaking the other.

**Accepted residual risk.** Cloudflare API permissions are zone-scoped and not
reliably record-scoped. A stolen DNS-edit token could alter other records in
`supermorphic.com`, redirect traffic, and assist in obtaining fraudulent certificates.
TLS and DNSSEC do not eliminate an authorised DNS-account compromise. Source-IP
restriction on the token is unusable because the permitted address is itself dynamic.
The available compensating controls are token expiry, credential separation, a
documented revocation procedure, and periodic review of the Cloudflare audit log.

## 9. Monitoring and alerting

**External reachability probing is deferred**, not adopted. The experiment is
operator-attended and time-boxed; a scheduled hosted probe would be the one component
that actively advertises the exposure, and this repository is public. Reachability
automation is reconsidered in the permanence decision.

**Adopted now:** an internal, credential-free **DDNS drift check**. It obtains the WAN
address as the Internet observes it from an IP-echo endpoint, resolves the public A
record from a public resolver, and alerts through the existing ntfy path on mismatch.
This detects the most probable failure — a stale record after a WAN address change —
entirely from inside the cluster, with no external vantage and no new disclosure.

**Not achievable, and deliberately not attempted:** a Gatus endpoint that appears to
test the public path. In-cluster DNS resolves the hostname privately, so such an
endpoint would silently test the internal path and report false confidence. The WAN
address is dynamic and cannot be pinned.

**Required for attribution:** access logging on the public Envoy data plane. Plex
displays the Envoy pod address for every proxied session, so per-client attribution
for public sessions exists only in Envoy's logs.

This means Envoy Gateway's **default access log to container stdout**, read live during
the experiment. No log aggregation, persistent sink, or retention policy is introduced:
the cluster runs no collector today, and adding one is outside this scope. Attribution
therefore does not survive pod restart or log rotation. That is accepted for an
attended, time-boxed experiment and is a named input to the permanence decision.

**Accepted blind spot.** Loss of Internet reachability caused by ISP filtering, DNAT
removal, or listener failure is not automatically detected. It presents as the Sonos
objective failing. This is accepted for the experiment and is a named input to the
permanence decision.

## 10. Staged sequence and hard gates

The agent stages and validates source. The operator runs all guarded recipes and every
UniFi and Cloudflare action.

| Phase | Steps | Gate to proceed |
|---|---|---|
| **0 — Preflight** (no changes) | Confirm UPnP/NAT-PMP disabled; inventory WAN forwards; create the scoped Cloudflare token with an expiry; prove UniFi accepts it; record the section 12 matrix as baseline | UniFi accepts the scoped token. Hard stop if a Global API Key is required |
| **1 — Observation** (no changes) | Hubble capture per section 7.1, including a live native Sonos session | An authoritative consumer list exists, with the Sonos path established |
| **2 — Containment** (cluster, no exposure) | 2a widen the controller watch selector; 2b add the Plex CiliumNetworkPolicy; 2c add the CI securityContext assertion | After 2a: all internal routes serve, Gatus fully green. After 2b: negative tests 6–9 pass **and** test 10 passes — every observed consumer still works, native Sonos included |
| **3 — Public data plane** (cluster, no WAN) | `networking-public` namespace and labels, MetalLB `public` pool, GatewayClass, EnvoyProxy, Gateway, dedicated Certificate, public HTTPRoute | Certificate Ready, Gateway Programmed, negative tests 1–5 pass, internal regression clean |
| **4 — Public DNS** (external, still unreachable) | Operator creates the Cloudflare A record; configures UniFi DDNS with the scoped token | A record matches the current WAN address; an address change propagates; **no AAAA exists**; internal Pi-hole record unchanged; from off-network, 443 is still closed |
| **5 — Activation** (operator, reversible in seconds) | One UniFi DNAT, WAN 443/TCP to the public VIP | External DNS/TLS checks, section 12 matrix, negative tests 11–13, rollback rehearsal |
| **6 — Decide** | Permanence proposed only after a clean run | Separate decision |

Phases 0 through 4 are all reversible without touching the internal path, and none of
them makes Plex reachable from the Internet. Exposure begins and ends with a single
UniFi rule in phase 5.

### 10.1 Hard gates — any one triggers immediate revert

1. UniFi requires a Global API Key.
2. Any internal consumer regresses, at any phase.
3. Any negative test fails.
4. Any hostname other than Plex routes on the public VIP.
5. Any WAN port other than 443/TCP is reachable.
6. An AAAA record exists for the hostname.
7. Plex opens its own port via UPnP.

## 11. Plex configuration requirements

- The custom server access URL remains `https://plex.lab.supermorphic.com`.
- Remote Access remains **enabled** — Relay depends on it — with **no** manually
  specified public port.
- UPnP and NAT-PMP remain disabled on UniFi. If enabled, Plex will attempt to open
  `32400` to the WAN itself, bypassing the DNAT, the dedicated Envoy, and this entire
  design. This is a required negative control, verified in phase 0.
- No unauthenticated networks are configured.
- The current **Secure connections** value is recorded during phase 0 and is not
  changed by this design. If the experiment requires changing it, that is a new
  decision, not an implementation detail.

## 12. Client acceptance matrix

Plex's dashboard cannot identify which path a client used, because every proxied
session displays the Envoy pod address. Three discriminators are recorded for every
row instead:

1. **Which Envoy pod address** appears in the session — the two data planes are
   distinct pods, so the address identifies the gateway. Both addresses are resolved
   at test time, since they change on restart.
2. **Presence in the public Envoy access log** — authoritative proof that a request
   crossed the WAN.
3. **Measured bitrate** — Relay caps at 2 Mbps, so any sustained higher rate is
   definitively not Relay.

**Procedural rule.** Force re-discovery before every row — restart the client, or sign
out and back in. Plex iOS caches discovery, and an uncontrolled cache already produced
one misleading measurement (section 3).

Run the full matrix twice: at phase 0 as baseline, and at phase 5 with the DNAT live.

| # | Client and action | Expectation | Gate |
|---|---|---|---|
| 1 | **Plexamp to Sonos, without AirPlay** | Player appears; switching succeeds; audio plays | **Primary objective** |
| 2 | Apple TV, local playback | Internal Envoy; connects normally | Hard |
| 3 | Native Sonos to Plex library | Unchanged from baseline | Hard |
| 4 | Plexamp "This device", local | Internal Envoy, not Relay, above 2 Mbps | Hard |
| 5 | Plex iOS local, 4K title | Internal Envoy, Direct Play, high bitrate | Hard |
| 6 | Plex Web, switch to Sonos | Switching succeeds | Soft |
| 7 | Off-site cellular, Wi-Fi disabled | Appears in the public Envoy access log; above 2 Mbps | Soft |
| 8 | Relay fallback, exercised separately | Relay serves when direct is unavailable | Soft |
| 9 | Tautulli | Continues recording sessions | Hard |
| 10 | Homepage Plex widget | Still populated | Hard |
| 11 | Gatus `plex` endpoint | Green throughout | Hard |

Recorded per row: network route label; video and audio disposition (Direct Play,
Direct Stream, or Transcode) **recorded separately from** the route; measured bitrate;
Envoy pod address observed; presence or absence in the public Envoy access log.

**Acceptance.** Success requires row 1 to pass **and** rows 2–5 and 9–11 to match
baseline. Failure is row 1 failing, or any hard row regressing. Either outcome removes
the DNAT immediately. Rows 6–8 do not gate.

## 13. Negative tests

Each isolation control has a test that proves it. Most require new guarded `*-verify`
recipes; these remain operator-only and outside `just ci`.

**Gateway scope** — before any DNAT exists, against the public VIP from the LAN:

1. Another `*.lab.supermorphic.com` hostname resolved to the public VIP must not reach
   that service.
2. Unknown or absent SNI, and a raw address with no Host header, must not be served by
   a default route.
3. Any port other than 443 on the public VIP is refused.
4. The Envoy admin endpoint is refused from another pod and from the VIP.
5. The internal VIP still serves every internal hostname.

**Containment** — after the policy, before any DNAT:

6. A pod in an unrelated namespace cannot reach `plex:32400`.
7. Plex cannot reach the Kubernetes API.
8. Plex cannot reach NAS administration, the UniFi gateway, or arbitrary VLAN hosts **on
   any port other than 443**. Egress to off-cluster hosts on 443 is permitted by the
   `world` entity (§7.2), so this test cannot disprove it.
9. Plex cannot reach another namespace's services.
10. Every consumer identified in phase 1 still reaches Plex.

**External** — operator-run from off-network, after the DNAT:

11. A port scan of the WAN address shows 443/TCP only.
12. A non-Plex hostname against the WAN address is not routed.
13. No AAAA record is published and IPv6 is not forwarded.

## 14. Failure handling and rollback

The organising principle is asymmetry: **rollback removes exposure, not containment.**

### 14.1 Order

| # | Action | Effect |
|---|---|---|
| 1 | Remove the single UniFi DNAT | Exposure ends in seconds. Sufficient on its own |
| 2 | Delete the public Cloudflare A record | Cleanup |
| 3 | Disable the UniFi DDNS entry, then revoke the token | Cleanup |
| 4 | Remove public Gateway resources | Cleanup |
| 5 | Revert the controller watch selector | Only when fully abandoning the design |

Internal DNS, the internal Gateway and HTTPRoute, the wildcard certificate, and the
VLAN rules are touched at no step.

**Step 1 is sufficient on its own.** Every later step is cleanup, so a partial or
interrupted rollback still leaves the system safe. This is the mitigation for
rollback-order error.

### 14.2 What is retained on failure

Phases 2a, 2b, and 2c are **kept — provided each passed its own gate.** Retention
applies only to changes proven non-regressive. If a phase-2 change is itself the cause
of an internal regression — a Cilium policy that breaks native Sonos, say — it is
reverted under §10.1 gate 2 and §14.3, because §2's non-regression constraint outranks
retention and a policy that breaks local playback is not a containment improvement.

Subject to that, the Cilium policy and the CI assertion are
containment improvements worth having whether or not Plex is ever published; removing
them would leave the cluster worse off than before the experiment. The widened
controller selector is inert once no namespace carries the `public` label, and
reverting it means re-touching the shared component every internal service depends on
— adding risk to buy nothing.

### 14.3 Failure classes

| Failure | Detection | Response |
|---|---|---|
| DDNS stale or stopped | Internal drift check to ntfy | Public path down, internal unaffected. Relay covers Plexamp music |
| WAN address changed | Drift check; external test | Wait for TTL plus client cache, re-test |
| Cloudflare API failure or rate limit | UniFi DDNS error; drift check | Degrades to a stale record |
| Cloudflare proxy accidentally enabled | External TLS check returns a Cloudflare certificate | Set `proxied=false` immediately. Plex breaks under proxy, and proxying video violates Cloudflare's terms |
| AAAA appears | Phase 4 gate, then periodic check | Delete it; confirm no IPv6 forwarding |
| Envoy vulnerability or suspected compromise | trivy-operator and upstream advisories | Remove the DNAT immediately. Internal path unaffected — separate data plane, separate key |
| Certificate renewal fails | Certificate not Ready | Public TLS fails; clients fall back to Relay where supported. Internal unaffected — separate certificate |
| Suspected Plex compromise | Tautulli sessions; public Envoy access log | Remove the DNAT, rotate the Plex token. The Cilium policy bounds lateral movement |
| Public denial of service | Link saturation; session count | Remove the DNAT. Plex has no rate limiting of its own |
| Internal regression at any phase | Gatus and the client matrix | Revert that phase's change only |

### 14.4 Rollback rehearsal

After the client matrix passes in phase 5, remove the DNAT and confirm Gatus stays
green and the internal matrix still passes, then decide whether to re-enable. This
proves the failure-domain invariant by executing it while attended, rather than
asserting it and discovering otherwise during an incident.

## 15. Security risk register

Ratings are qualitative and use the scale of the 2026-08-02 register. Likelihood and
impact are rated separately, and **exposure is rated separately from successful
exploitation**.

### 15.1 The exposure/exploitation distinction

| | Relay baseline | Direct `32400` | Dedicated Envoy |
|---|---|---|---|
| Discovery and probing | Low | **Certain** · impact Low | **Certain** · impact Low |
| Successful exploitation of the public listener | Low · High | Medium · High | Low–medium · High |

**Envoy does not authenticate.** It terminates TLS, normalises HTTP, and rejects
malformed input, so the pre-authentication protocol and parser surface facing the
Internet becomes a hardened, audited edge proxy rather than a media server. The Plex
**application** surface behind it remains fully reachable through the route. The
improvement over direct exposure is real and narrower than intuition suggests.

### 15.2 Retained risks and their deltas

| Threat | Relay | Direct | Envoy | Residual risk |
|---|---|---|---|---|
| Plex account or token compromise | Medium · High | Medium · High | Medium · High | Unchanged — a stolen token works over Relay too |
| Media destruction or exfiltration | Low · High | Low · High | Low · High | Read-only media is the control; exfiltration remains possible |
| Kubernetes API abuse | Low · High | Low · High | Low · High | No service-account token; node escape bypasses this |
| Container, kernel, runtime, or GPU escape | Low · Severe | Low · Severe | Low · Severe | Hardware transcoding exposes the GPU driver. **New:** `media` enforces PSA `privileged`, so pod hardening has no admission backstop |
| Plex process compromise | Low–medium · High | Medium · High | Low–medium · High | Attacker controls the writable config PVC and process memory |
| Lateral movement to cluster or VLANs | Medium before policy, Low after | as Relay | as Relay | Rating unchanged; consequence is worse because compromise is likelier. Policy is now a hard prerequisite |
| Supply-chain compromise | Low–medium · High | Low–medium · High | Low–medium · High, larger surface | Envoy Gateway controller and proxy images join the pinned-artifact surface |
| Configuration regression | Medium · Medium | Medium · Medium | Medium · Medium | Rating unchanged, but the **exposed surface grows more here than anywhere else in this design**: a namespace, GatewayClass, EnvoyProxy, Gateway, Certificate, HTTPRoute, MetalLB pool, an edit to the shared controller, and two external systems. This is what the staged gates and negative tests exist to control |
| Third-party privacy exposure | Medium · Medium | **Low · Medium** | **Low · Medium** | **Improves.** Media no longer transits Plex relay infrastructure |
| Availability and bandwidth | Medium · Low–medium (2 Mbps cap) | Medium · Medium | Medium · Medium | Relay's ceiling is removed; public denial of service becomes possible |

### 15.3 New risks

| Threat | L · I | Principal controls | Residual risk |
|---|---|---|---|
| DDNS credential compromise | Low · **High** | Token separate from cert-manager's, zone-scoped, with expiry; revocation procedure; audit-log review | Cloudflare cannot scope to a single record. An authorised DNS compromise is not eliminated by TLS or DNSSEC |
| Source-address loss and audit limitation | **Certain** · Low–medium | Public Envoy access logging | Plex attributes every proxied session to the Envoy pod. Plex's own logs cannot distinguish Internet from LAN clients |
| Public listener or HTTPRoute misconfiguration | Medium · High | Exact-hostname listener, distinct namespace label, negative tests 1–5 | Gateway API guarantees hostname intersection; operator error in labels remains possible |
| Accidental public AAAA | Low · **High** | Phase 4 gate, periodic check | No IPv6 firewall design exists; an AAAA would expose an unfiltered path |
| Stale DNS pointing to a reassigned address | Medium · Medium | TTL 300; drift check | A stranger receives failed TLS attempts and the SNI value |
| Public denial of service or resource exhaustion | Medium · Medium | Remove the DNAT | Plex has no rate limiting; Envoy connection limits are not configured in this design |
| DDNS update failure | Medium · Medium | Internal drift check to ntfy | Public path is down until corrected |
| Envoy vulnerability or compromise | Low–medium · High | Separate data plane; dedicated certificate, so compromise does not yield the wildcard key; trivy-operator; prompt updates | An Envoy compromise still proxies to Plex and holds the Plex hostname's key |
| Monitoring blind spot | Medium · Medium | Drift check; attended experiment | Loss of Internet reachability is not automatically detected |
| Accidental shared-gateway exposure | Low · **Severe** | Separate namespace requiring a ReferenceGrant that will not exist; separate GatewayClass; negative test 5 | A deliberate future edit could still create the grant |
| Backend-hop plaintext | Low · Low–medium | Cilium policy restricting who reaches `32400` | Accepted. WireGuard is the correct fix and is out of scope |
| TLS key compromise or certificate expiry | Low · Medium | Scoped to the Plex hostname only; cert-manager renewal | Public TLS failure degrades to Relay where supported |
| Cloudflare API failure or rate limiting | Low · Low–medium | Drift check | Degrades to a stale record |
| Accidental Cloudflare proxy enablement | Low · Medium | Phase 4 verification; external TLS check | Breaks Plex and violates Cloudflare's terms for video |
| DNS and client caching after a WAN change | Medium · Low | TTL 300 | Clients may hold a stale address beyond TTL |
| Rollback-order error | Low · Medium | Step 1 alone ends exposure | Cleanup steps may be left incomplete without safety impact |

### 15.4 Summary judgement

The dedicated external Envoy is meaningfully safer than direct publication of Plex
`32400` — principally by keeping the wildcard key out of the exposed pod, placing a
hardened edge proxy ahead of Plex's protocol parser, and making misconfiguration
structurally difficult. It is meaningfully riskier than Relay, which has no public
listener at all. These are two different orderings and both are intended: by **risk
ascending** the order is Relay, dedicated Envoy, direct publication; by **preference**
the approved order is dedicated Envoy, then direct, then Relay, because Relay's lowest
risk comes with an inability to meet the objective. The approved preference ranking
holds.

The largest genuine cost is not exploitation but **configuration regression across a
substantially larger surface**, which is why the staged gates and negative tests carry
most of the weight in this design.

## 16. Implementation boundaries

- No internal DNS, internal HTTPRoute, wildcard certificate, or VLAN rule is modified.
- The controller watch selector change is staged independently and regression-tested
  before any public resource exists.
- The Cilium policy is derived from observation and proven before public ingress.
- All cluster mutations and health checks run through guarded `just` recipes. New
  `*-verify` recipes are operator-only and stay out of `just ci`.
- The operator performs all UniFi and Cloudflare actions and holds all credentials.
- This repository is public. No live public address, hardware serial, or credential is
  recorded in this document or in any artifact produced by this design.

## 17. Decision record

| Decision | Outcome |
|---|---|
| Primary remote path | Dedicated external Envoy on one WAN TCP 443 DNAT |
| Fallback order | Plex Relay is the only fallback exercised in this experiment. Direct Plex `32400` remains ranked second overall but is **not** enabled here and would require its own authorisation |
| Public hostname | `plex.lab.supermorphic.com`, split horizon, one FQDN |
| Public TLS | Dedicated certificate for the Plex hostname only |
| Wildcard key exposure | Never leaves the internal Gateway |
| Public Gateway namespace | `networking-public`, isolating the wildcard secret behind a ReferenceGrant |
| Route admission | Exact-hostname listener plus a distinct namespace label |
| Backend hop | Plaintext, accepted; BackendTLSPolicy rejected; WireGuard out of scope |
| DNS | Cloudflare authoritative, A record only, `proxied=false`, TTL 300 |
| DDNS | UniFi-managed, least-privilege scoped token with expiry, separate from cert-manager's |
| External monitoring | Deferred; internal DDNS drift check adopted |
| Session attribution | Public Envoy access logs; Plex's route label is not a path signal |
| Containment prerequisite | Hubble-observed Cilium policy, proven before exposure |
| Admission backstop | CI assertion pinning Plex securityContext |
| Exposure control | One UniFi DNAT; removing it is a complete rollback |
| On failure | Exposure removed, containment retained |
| Permanence | Not decided here. Separate decision after a clean experiment |
