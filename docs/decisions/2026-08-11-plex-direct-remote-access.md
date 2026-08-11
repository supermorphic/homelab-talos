# Plex direct remote access — decision

- **Status: Accepted.**

Date: 2026-08-11.
Branch: `investigate-plex-remote-access`.

Supersedes [Plex public Envoy and split-horizon remote access — amendment](2026-08-03-plex-public-envoy-amendment.md),
whose selected remote path failed its own acceptance gate.

Activates §8.3 of [Plex Relay and Sonos integration — design](2026-08-02-plex-relay-sonos-design.md),
which specified this fallback in advance and gated it on explicit authorisation.

## 1. Decision

Publish Plex to the Internet through **one UniFi DNAT to Plex's own listener on TCP
`32400`**, and let Plex publish its native `*.plex.direct` connection. Retain the
custom server access URL so local clients continue to reach Plex through the internal
Envoy Gateway at full bitrate. Retain Relay as the fallback it already is.

This is authorised as a **staged, operator-attended experiment**, not as a permanent
configuration. Permanence is a separate decision.

### 1.1 What is superseded

| 2026-08-03 amendment decision | Status |
|---|---|
| Dedicated external Envoy Gateway as the primary remote path | **Superseded.** It failed §12 row 1 |
| Split-horizon DNS on `plex.lab.supermorphic.com` for the public horizon | **Superseded.** The public horizon is now Plex's own `plex.direct` name |
| Public Gateway, `networking-public`, dedicated certificate, public MetalLB pool | **Superseded.** Removed in stage 5 |
| UniFi-managed Cloudflare DDNS and the credential-free drift exporter | **Superseded.** Removed in stage 5 |
| "Direct publication of Plex `32400` remains rejected" | **Superseded.** It is the selected path here |

### 1.2 What is retained

Everything the amendment built that is not the public data plane:

- the widened Envoy controller watch selector, inert and left alone;
- the Plex `CiliumNetworkPolicy`, extended rather than removed;
- the CI `securityContext` assertion pinning Plex's runtime hardening;
- the internal Envoy Gateway, wildcard certificate, internal `HTTPRoute`, and Pi-hole
  records, none of which were ever rollback targets;
- `timeouts.request: 0s` on both Plex routes, without which long transfers reset at 15s;
- every §6 control of the 2026-08-02 design, which §8.3 requires as a precondition.

## 2. Why the public Envoy failed

The dedicated Envoy plane was built, activated, and measured. It passed every gate
except the one that mattered.

| Gate | Result |
|---|---|
| Gateway Programmed at the dedicated VIP | Pass |
| Dedicated single-hostname certificate presented externally | Pass — `CN=plex.lab.supermorphic.com`, not the wildcard |
| Negative tests 11–13 from off-network | Pass — only TCP 443 open, wrong hostname reset, no AAAA |
| Access-log canary | Pass — query string and token absent, source attribution present |
| Hard rows 2–5 and 9–11 | Pass — no internal regression |
| Row 7, off-site cellular above 2 Mbps | Pass |
| **Row 1 — Plexamp switches to Sonos and plays** | **Fail.** Switch succeeded; playback never started |

§12's acceptance rule is that row 1 failing is a failed experiment. The DNAT was
removed and the rollback rehearsed.

### 2.1 Root cause

With the DNAT live, Plex's cloud Sonos service reached the server through the public
Envoy and completed `/identity`, `/playQueues`, and metadata calls with HTTP 200. The
speaker then reported `state=stopped` at 35 ms of a 160-second track with an **empty
`url=`**, and Plex logged `HTTP error requesting GET (3, URL using bad/illegal format
or missing URL)`. No audio fetch ever reached either Envoy data plane.

Plex could not construct a media URL to hand the speaker.

### 2.2 Why, precisely

Every connection Plex hands a client is a `*.plex.direct` name whose certificate Plex
controls and every Plex client trusts implicitly. Relay connections are
`*.relay.plex.direct`; direct remote connections are `<dashed-ip>.<hash>.plex.direct`.

The amendment's public horizon was the operator's own hostname on TCP 443, terminated
by Envoy with an operator-issued certificate. That is not a `plex.direct` name. Plex's
cloud service tolerated it for control-plane calls; the speaker could not use it, so
Plex supplied nothing.

The exact-hostname listener that refused everything else — §6.2 control 2, verified by
negative test 12 — is the same property that made the path unusable for Sonos. The
isolation control and the failure are the same mechanism.

## 3. Evidence

Measured on the current build, 2026-08-11, with the DNAT already removed.

| `customConnections` | Local clients | Plexamp → Sonos |
|---|---|---|
| Set to the internal hostname | Internal Envoy, Direct Play, 4K HDR10, 107.5 Mbps | **Fails** |
| Cleared | **All clients fall to Relay**, ≤2 Mbps, transcoded, reported Indirect | **Plays** |

Neither state satisfies §2 of the amendment, which requires the objective **and** no
hard-row regression. The custom access URL is the coupling: it is load-bearing for
local playback and fatal to the Sonos cast path.

Plex's mapping state remained `Mapped - Not Published (Not Reachable)` in **both**
states, including while Sonos played. Reachability state is therefore not the
discriminator; the connection's name is.

### 3.1 A measurement that nearly misled

Immediately after clearing the custom URL, Apple TV still showed Direct Play at
107.5 Mbps through the internal Envoy. Signing out and back in — forcing genuine
rediscovery — dropped it to Indirect below 2 Mbps. The healthy reading was a **cached
connection entry**, not a working path.

Recorded because it is the second time in this investigation that cached Plex client
discovery produced a false pass, and because the failure mode is silent: the
configuration looks stable until the cache expires.

## 4. Corrections to earlier accepted records

Superseded, never revised. The corrections are recorded here.

**The Phase 1 capture's central finding was a false inference.**
[2026-08-03-plex-containment-capture.md](2026-08-03-plex-containment-capture.md) §2
concluded that native Sonos "cannot currently reach Plex" because its playback produced
zero ingress flows to `plex:32400`. Native Sonos was working the whole time, over
Relay. Relay terminates on pod loopback `127.0.0.1:32401`, so a Cilium ingress capture
on `32400` cannot observe it by construction. Zero flows is what a *working* Relay
session looks like.

The superseded amendment's §7.1 prerequisite that the capture was trying to satisfy was
therefore unobtainable for a reason unrelated to the fault under investigation, and the
deviation recorded there can be closed rather than carried.

**The amendment's §3 understated the cost of clearing the custom URL.** It recorded
"Apple TV cannot connect to Plex at all". On the current build Apple TV connects and
plays — degraded to Relay, capped and transcoded. The practical conclusion is
unchanged and the mechanism is clearer: clearing the custom URL costs every local
client its direct path, not just Apple TV its route.

**The amendment's largest predicted risk materialised.** §15.2 rated configuration
regression `Medium · Medium` and stated the exposed surface "grows more here than
anywhere else in this design". Delivery required four follow-up pull requests to
correct defects, froze all Flux reconciliation cluster-wide for roughly 35 minutes on a
MetalLB admission deadlock, and failed three guarded bootstrap attempts. The prediction
was correct, and it is evidence for preferring the smaller surface this decision
selects.

## 5. Architecture

### 5.1 Local horizon — unchanged

```
plex.lab.supermorphic.com
  -> Pi-hole private answer
  -> internal Envoy Gateway (MetalLB 192.168.90.30)
  -> Service plex:32400
```

Advertised to clients by the retained custom server access URL. This is the path that
delivers Direct Play at full bitrate and it is not modified.

### 5.2 Remote horizon — new

```
<dashed-ip>.<hash>.plex.direct:32400        (published by Plex, certificate held by Plex)
  -> current residential WAN IPv4
  -> one UniFi DNAT: WAN TCP 32400 -> 192.168.90.31:32400
  -> Service plex (LoadBalancer) -> Plex Media Server
```

Plex publishes and maintains this name itself. No operator DNS record, no DDNS, and no
operator-issued certificate participates in the remote path.

### 5.3 Isolation invariants

- Exactly one WAN rule exists: TCP `32400` to `192.168.90.31`.
- UPnP and NAT-PMP remain disabled; Plex must never open its own mapping.
- No public IPv6 and no AAAA record.
- The wildcard certificate and its key never leave the internal Gateway. Plex serves
  its own `plex.direct` certificate, so no operator-controlled key is Internet-facing.
- Relay remains enabled as the fallback.
- The internal Gateway, its route, and internal DNS are untouched.

## 6. Components

Three changes, and no more.

**A dedicated LoadBalancer address for Plex.** The Plex Service becomes
`type: LoadBalancer` with an explicit `metallb.io/loadBalancerIPs: 192.168.90.31` from
the existing `internal` pool, which has `autoAssign: false`.

No new MetalLB pool is created. The amendment's §6.2 control 4 wanted a dedicated pool
for "a stable, unambiguous DNAT target that cannot drift onto another service";
`autoAssign: false` with an explicit address already guarantees that. Creating a pool
requires narrowing `internal` in the same change, which is exactly the MetalLB
admission deadlock that froze reconciliation cluster-wide. The simpler form removes a
failure mode without giving up the property.

**`externalTrafficPolicy: Local`,** preserving the real client source address. Plex's
own logs then attribute remote sessions, its `LAN Networks` bandwidth classification
stays correct, and the operator can review who connected. The alternative, `Cluster`,
would need no policy change at all because the existing `fromEntities: [host,
remote-node]` rule already covers node-sourced traffic — but it SNATs every remote
client to a node address and destroys attribution on the one service being published.
§9 of the amendment treated attribution as a requirement; blindness is not an
acceptable price for leaving a policy file untouched.

**The Plex CiliumNetworkPolicy gains `world` ingress on `32400`.** This is the real
containment cost and is accepted openly: publishing Plex means the Internet must reach
that port. Everything else in the policy holds unchanged — egress remains cluster DNS
plus off-cluster HTTPS with every private, shared, and documentation range excluded,
and no other port, source, or destination opens.

**Plex settings.** Remote Access stays enabled. The manually specified public port is
set to `32400`, matching the UniFi rule, as §8.3 requires. The custom server access URL
is restored **with an explicit port**, as `https://plex.lab.supermorphic.com:443/`.

The port is not optional. Plex applies the Remote Access port to any custom URL that
omits one, so the previously stored portless value would publish
`plex.lab.supermorphic.com:32400` once the manual port is set. Pi-hole resolves that
name to the internal Gateway VIP, which listens only on `443`, so a rediscovering local
client would follow the published connection to a port nothing serves and fall back —
regressing the hard local rows this design exists to protect.

Unauthenticated networks stay empty. The current **Secure connections** value is
recorded before any change and is not changed by this decision; changing it would be a
new decision.

The default port `32400` is used rather than a non-standard external port. A high
random port is cheap obscurity and a reasonable later hardening step, but it is an
untested variable in a design whose entire purpose is establishing whether Sonos works,
and this investigation has repeatedly been cost by changing more than one thing at
once.

## 7. Staging and gates

The agent stages and validates source. The operator runs every UniFi action and every
guarded recipe.

| Stage | Steps | Gate to proceed |
|---|---|---|
| **1 — Cluster, no exposure** | LoadBalancer Service at `.31`; CNP `world:32400` | Plex healthy internally; `.31` assigned; from off-network nothing is reachable |
| **2 — Detection** | Companion decision designed, implemented, and exercised | Alerts fire on synthetic abuse and reach ntfy |
| **3 — Exposure** | Plex manual public port `32400`; one UniFi DNAT | Plex publishes a `*.plex.direct` remote connection |
| **4 — Acceptance** | Full client matrix against the phase-0 baseline; external negative scans | Row 1 passes **and** rows 2–5 and 9–11 match baseline |
| **5 — Teardown** | Remove the superseded public plane | Only after stage 4 passes |
| **6 — Decide** | Permanence proposed only after a clean run | Separate decision |

Stage 3's gate is the connection Plex publishes, not the reachability state it reports.
§3 measured Sonos playing while the state read `Mapped - Not Published (Not Reachable)`,
so that state demonstrably does not prevent Plex from constructing a media URL and
cannot serve as a precondition. What §2.2 identifies as the mechanism is the
connection's *name*, and whether Plex now publishes a `*.plex.direct` remote connection
is directly observable in its published resource list.

The mapping state remains worth recording as an indicator — it is the observable that
failed throughout the Envoy experiment — but it does not gate the stage.

Stage 5 removes the superseded machinery through two different mechanisms, because it
lives in two different places. The public Gateway, `networking-public`, and the DDNS
drift exporter are Flux-managed and come out through a reviewed Git revert, never a
live edit. The public Cloudflare A record, the UniFi DDNS entry, and the scoped token
are external state the operator created directly; no Git change can delete, disable, or
revoke them, so each is an explicit operator action with the token revocation last. It
is deliberately gated: the
superseded machinery is the fallback position until the replacement is proven.

### 7.1 Detection and alerting precede durable exposure

Nothing in this cluster would notice this port being abused. Hubble is enabled, but
`hubble-metrics` is not configured and no ServiceMonitor scrapes Cilium or Hubble into
Prometheus. Plex records every request with its source address, but writes it to its
config PVC, and the cluster runs no log collector — a fact the superseded amendment
already noted about its own access logs. Probing, a connection flood, repeated
authentication failures, and bandwidth saturation would all pass unobserved and leave no
durable evidence.

**No exposure begins until detection exists and has been shown to work.** Stage 2 is a
gate, not a parallel track: the DNAT is not created until alerts demonstrably fire on
synthetic abuse and arrive over the existing ntfy path. Being attended is not a
substitute — an operator watching a dashboard is not a detection system, and the
superseded design's time-boxed-and-attended reasoning is deliberately not reused here.

Their design is deliberately not attempted here, because appending it would be worse
than giving it a proper pass. A companion decision must cover at minimum: which signals
are already available and which require enabling `hubble-metrics` plus a ServiceMonitor;
what constitutes an attack expressed in those signals rather than in adjectives; which
alerts route through the existing ntfy path; how each alert is proven to fire, since an
untested alert rule is not detection; and whether any rate limiting is achievable
without reintroducing a proxy in front of Plex, given that removing that proxy is what
this design does.

**Thresholds cannot be derived from a measured baseline of remote traffic**, because no
remote traffic exists until the DNAT does, and the DNAT is gated on this work. Requiring
one would repeat the mistake §4 records: the superseded design made a native Sonos
capture a prerequisite for a policy that had to exist before native Sonos could work,
and the prerequisite was unobtainable by construction. The companion decision must
instead set initial thresholds from the *local* traffic profile and from what the link
can physically carry, treat them as provisional, and tune them once real remote traffic
exists. Provisional-and-stated beats precise-and-impossible.

Two measures are available immediately and need no cluster change: UniFi's syslog option
on the forwarding rule itself, and Plex's existing per-user remote stream limit of `2`
from §10 of the 2026-08-02 design.

### 7.2 Hard gates — any one triggers immediate revert

1. Any internal consumer regresses, at any stage.
2. Row 1 fails at stage 4.
3. Any WAN port other than `32400`/TCP is reachable.
4. An AAAA record exists for any published Plex name.
5. Plex opens its own port via UPnP or NAT-PMP.

## 8. Rollback

The organising principle is unchanged: **rollback removes exposure, not containment.**

| # | Action | Effect |
|---|---|---|
| 1 | Remove the single UniFi DNAT | Blocks new connections in seconds. Established sessions may survive |
| 2 | Terminate any established session | Mechanism undecided; see below |
| 3 | Clear Plex's manually specified public port | Plex stops advertising a direct remote connection |
| 4 | Revert the Service and CNP change in Git | Only when abandoning the design |

Local access never depended on any of this and is unaffected by steps 1, 3, and 4.

**Step 1 is not complete rollback.** Deleting a forwarding rule blocks new connections
but does not necessarily drop sessions UniFi already holds in conntrack; the accepted
runbook records exactly this and follows DNAT deletion with a connection flush. The
superseded design could flush by restarting the public Envoy, which left local playback
untouched because local traffic used a different data plane. That option does not exist
here: under direct exposure Plex is itself the listener, so any equivalent flush
interrupts every client, local ones included.

The mechanism for step 2 is therefore not settled by this decision and must be chosen
before stage 3. Until it is, rollback should be treated as blocking new exposure rather
than ending it outright.

## 9. Risk

Ratings use the scale of the 2026-08-02 register. The delta from the superseded design
is narrower than the change in mechanism suggests.

| Threat | Envoy design | **This design** | Notes |
|---|---|---|---|
| Discovery and probing | Certain · Low | Certain · Low | Unchanged. `32400` is a more recognisable port than `443` |
| Successful exploitation of the public listener | Low–medium · High | **Medium · High** | Plex's own HTTP/TLS parser faces the Internet with no hardened proxy ahead of it, and no SNI filtering |
| Plex process compromise | Low–medium · High | **Medium · High** | The one row that moves |
| TLS key compromise | Low · Medium | **Low · Low** | Improves. No operator-controlled key is Internet-facing |
| Configuration regression | Medium · Medium | **Low · Medium** | Improves materially. Three changes replace a namespace, GatewayClass, EnvoyProxy, Gateway, Certificate, HTTPRoute, MetalLB pool, a shared-controller edit, and two external systems |
| Third-party privacy exposure | Low · Medium | Low–medium · Medium | Sonos playback transits Relay; local playback does not |
| Lateral movement | Low after policy | Low after policy | Policy retained and extended, not removed |

**The Plex application surface is unchanged.** §15.1 of the amendment already conceded
that Envoy does not authenticate and that the Plex application behind it "remains fully
reachable through the route". What is genuinely given up is the pre-authentication
protocol and parser surface being a hardened, audited edge proxy rather than Plex's own
HTTP stack.

Compensating controls, all already in force and all required by §8.3 as preconditions:
non-root UID/GID `568`, dropped capabilities, no privilege escalation, `RuntimeDefault`
seccomp, no service-account token, pinned image digest, read-only media, the retained
Cilium policy bounding egress and lateral movement, and trivy-operator with prompt
patching. Plex CVE currency matters more under this design than under the previous one,
and that is accepted.

**Accepted new risk.** Plex has no rate limiting of its own, so a public denial of
service against `32400` is possible and is answered by removing the DNAT.

## 10. Validation

- A source validator asserting the Plex Service shape: `LoadBalancer`, explicit
  `192.168.90.31`, `externalTrafficPolicy: Local`, port `32400` only.
- The same validator asserting the CNP admits `world` on `32400` and that no other
  ingress source, port, or egress destination widened.
- Existing guarded `plex-verify` for live acceptance.
- External negative scans from off-network proving only `32400`/TCP answers, no AAAA
  exists, and no other port is reachable.
- `mise exec -- just ci` before every pull request.

Every validator assertion must encode a genuine invariant or use an independent oracle.
Where a guard is added, it is proven by reintroducing the defect and confirming the
suite fails.

## 11. Decision record

| Decision | Outcome |
|---|---|
| Primary remote path | One WAN TCP `32400` DNAT to Plex's own listener |
| Remote name and certificate | Plex-published `*.plex.direct`; no operator key exposed |
| Local path | Unchanged; internal Envoy via the retained custom access URL |
| Fallback | Relay, retained and already serving native Sonos |
| MetalLB address | `192.168.90.31`, explicit, from the existing `internal` pool; no new pool |
| Service policy | `externalTrafficPolicy: Local`, preserving client attribution |
| Containment | Plex Cilium policy retained and extended with `world:32400` only |
| Public Envoy plane | Superseded; removed in stage 5 after the replacement is proven |
| DDNS, public A record, scoped token | Superseded; removed in stage 5 |
| Plex public port | `32400`, matching the UniFi rule; non-default port deferred |
| Secure connections | Recorded, unchanged; changing it is a new decision |
| Exposure control | One UniFi DNAT; removing it blocks new connections. Terminating established sessions needs a mechanism not yet chosen |
| Detection and alerting | Absent today. A precondition of durable exposure, designed in a companion decision |
| Permanence | Not decided here. Separate decision after a clean experiment |
