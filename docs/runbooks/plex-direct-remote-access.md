# Plex direct remote access — exposure runbook

Procedure for the permanent design in
[Plex direct remote access — permanence decision](../decisions/2026-08-22-plex-direct-remote-access-permanence.md),
including the stages and phase-0 baseline from the superseded experiment decision.

This runbook publishes Plex to the Internet. Everything before it created capability
without exposure; this is the step that changes what the world can reach. Read
[§7.2](../decisions/2026-08-11-plex-direct-remote-access.md) before starting — four
conditions require an immediate revert, and one of them is checked before you begin.

> **Time boundary:** this runbook includes the 2026-08-12 experiment record. Statements
> below about no DNAT, synthetic-only traffic, recorded Plex settings, and acceptance
> results describe that dated run. They do not prove current UniFi, Plex, DNS, IPv6, or
> cluster state. The permanence decision retains the successful design but does not turn
> historical evidence into continuous proof. Use
> [Current-state verification](#current-state-verification) before relying on the
> exposure today.

Detection is a precondition. For the dated experiment, Stage C of
[Plex remote access detection](plex-remote-access-detection.md) was exercised on
2026-08-12: a half-open scan from the LAN produced ~16.5 connections/sec, all three
detection alerts fired, and all three reached ntfy. Verify current detector health
before relying on that result. Two forms of abuse remain
**unobserved** — repeated authentication failures and bandwidth saturation — and the
decision's §2 says stage 3 proceeds with that stated, or it does not proceed.

## Recorded stage-3 starting state — 2026-08-12

At the start of the recorded experiment, stages 1 and 2 were merged and observed live:

- Plex Service is `LoadBalancer` at `192.168.90.31`, `externalTrafficPolicy: Local`.
- The Plex CiliumNetworkPolicy admits `world` on TCP `32400` and nothing else.
- Hubble flow metrics are scraped; five `plex-remote-access` alerts are loaded and
  evaluating.
- **No DNAT exists.** `192.168.90.31:32400` is reachable from the LAN only, because
  Cilium's `world` entity includes LAN addresses.
- No off-cluster client has ever connected. The inbound SYN series exists only from the
  stage C exercise.

These last two statements are historical pre-exposure evidence, not current-state
assertions.

## Current-state verification

Keep current claims separated by authority. Git defines desired cluster state; the live
cluster, UniFi, Plex, Pi-hole, account, and ISP settings require their own checks. Record
only sanitized outcomes in the public repository. Keep public addresses, rule IDs,
account identifiers, client addresses, and raw flow or scan output private.

### Repository and cluster

1. Confirm Git still declares one Plex `LoadBalancer` address, `externalTrafficPolicy:
   Local`, `allocateLoadBalancerNodePorts: false`, and TCP `32400` only. Run the source
   gate:

   ```bash
   mise exec -- just kube plex-validate
   ```

2. With the scoped worktree kubeconfig, run the established read-only live verifier:

   ```bash
   mise exec -- just kube plex-verify
   ```

3. Inspect the live Service, its ready endpoints, and the applied policy:

   ```bash
   mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
     --namespace media get service plex --output yaml
   mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
     --namespace media get endpointslice \
     --selector kubernetes.io/service-name=plex --output yaml
   mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
     --namespace media get ciliumnetworkpolicy plex --output yaml
   ```

   Confirm the Service has one TCP application port, no allocated NodePort, and a ready
   Plex target in the EndpointSlice. If any additional listener exists, stop this
   verification path and include it in the privately recorded off-network filtering
   test; record only the sanitized pass or fail outcome publicly. These reads prove
   object state, not packet enforcement. The
   established enforcement proof is the operator-attended, state-changing
   `plex-network-policy-test`, which creates and removes run-scoped probe Pods and
   requires `PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy'`. Run it in an
   approved window before treating source validation as deployed containment.

### UniFi and external path

1. Inventory all WAN forwards. Confirm one intentional Plex rule, TCP only, one public
   port, one destination, and internal TCP `32400`. Confirm there is no duplicate,
   wildcard, range, UDP, or automatically created mapping.
2. Confirm UPnP and NAT-PMP remain disabled and that no other feature can create WAN
   mappings automatically.
3. Confirm Intrusion Prevention remains in Notify and Block mode, the Servers network is
   protected, the intended Standard categories are active, and no unintended exclusion
   exists. Confirm the detection engine and normal UniFi update channels are current.
4. Test from an actually off-network source. Confirm only the intended TCP path answers.
   A LAN scan is not evidence of WAN filtering.
5. Verify IPv6 separately: delegated prefixes, global node addresses, public DNS answers,
   unsolicited-inbound UniFi policy, and an off-network IPv6 connection attempt. IPv4
   DNAT state does not establish IPv6 safety.

### Plex, detection, and recovery

1. Record Remote Access, the manual public port, Relay, authentication-bypass networks,
   Secure Connections, the IPv4-only client-network setting, and custom access URLs.
   Compare them with the permanence decision. The list must contain exactly the one
   measured Plex-managed URL and must not advertise the internal Envoy hostname.
2. Follow [Plex remote-access detection](plex-remote-access-detection.md) to confirm
   Hubble metrics, Prometheus rules, Alertmanager, and ntfy are healthy. Historical
   Stage-C results do not prove current detector health.
3. Confirm the rollback owner can remove the DNAT. Remember that established conntrack
   sessions can survive rule removal; restart Plex only when session eviction is the
   intended incident action.
4. Confirm the Plex configuration backup and independent media recovery paths are
   healthy before treating recovery as an effective control.

A dated, sanitized record of these checks supplies evidence for the current operating
state. It is not continuous proof; the permanence decision defines the accepted design
and the events that require review.

## Phase 0 — baseline, before touching anything

The baseline is a pre-exposure measurement. It exists so that after publishing you can
prove nothing internal regressed. **It stops being capturable the moment the DNAT
exists**, so do this first and in one sitting.

The superseded runbook's phase 0 also mapped internal Envoy pod addresses. That step is
obsolete: it existed to tell two Envoy data planes apart in logs, and this design has
only one. Remote clients now reach Plex directly and Plex records their real addresses,
because `externalTrafficPolicy: Local` preserves them.

### 0.1 Record Plex settings without changing them

Captured 2026-08-12, before any stage 3 change:

| Setting | Expected | Recorded | |
|---|---|---|---|
| Remote Access | enabled | enabled | ✅ |
| Manually specify public port | disabled | disabled | ✅ |
| Enable Relay | enabled | enabled | ✅ |
| Secure connections | *record, do not change* | **Preferred** | recorded |
| Allowed without auth | empty | empty | ✅ |
| Remote streams allowed per user | `2` | was `unlimited`, **now `2`** | ✅ fixed, see 0.1.1 |
| Custom server access URL | *record verbatim* | `https://plex.lab.supermorphic.com` — **no port** | ⚠️ see 0.1.2 |
| LAN Networks | must include the pod network | `192.168.10.0/24,192.168.12.0/24,192.168.20.0/24,10.244.0.0/16` | ✅ fixed, see 0.1.3 |

Two of the eight did not match and both are now corrected. The custom access URL is the
only outstanding item, and it is deliberately left alone — step 3.1 fixes it as the first
action of stage 3, because changing it now would publish the wrong value the moment the
manual public port is enabled.

### 0.1.1 Remote streams per user is unlimited, and the design assumes `2`

The invariants table in the superseded runbook requires `2`, and §2 of the detection
decision leans on it: bandwidth saturation is explicitly **deferred and unobserved**, and
the per-user remote stream limit is named as the thing partially bounding it. With the
limit unset, that risk is neither detected nor bounded.

**Set to `2` on 2026-08-12**, before the baseline, so the baseline reflects the
configuration stage 3 runs under. This restored a documented invariant rather than making
a new decision — unlike Secure connections, which §6 explicitly freezes at `Preferred`.

The risk §2 describes as "deferred but partially bounded" was, until this change,
unbounded. The control the acceptance rested on had never been configured.

**Check one thing first, and it is not a formality.** Confirm in Tautulli that a local
session registers as **LAN**, not WAN. If Plex classifies local sessions as remote, a
limit of `2` throttles the household rather than bounding remote abuse.

This check ran on 2026-08-12 and **returned WAN**. See 0.1.3 — LAN Networks omitted the
pod network, so every local session was being treated as remote. It is fixed, and local
sessions now register as LAN. Had the limit been set to `2` first, the household would
have been capped at two concurrent local streams.

### 0.1.2 The custom URL has no port — this is the documented trap, and it is live

§6 records that Plex applies the Remote Access port to any custom URL omitting one. The
stored value is portless, so the moment the manual public port is set, Plex would publish
`plex.lab.supermorphic.com:32400`. Pi-hole resolves that name to the internal Gateway
VIP, which listens only on `443`.

It is harmless right now only because the manual public port is disabled. Step 3.1 fixes
it, and 3.1 runs before 3.3 for exactly this reason.

### 0.1.3 LAN Networks omitted the pod network — every local session was classified WAN

**Found and fixed 2026-08-12.** The Tautulli check in 0.1.1 returned **WAN** for a local
phone session, and playback was stuttering.

Local clients do not reach Plex directly. They go through the internal Envoy, so Plex
sees the Envoy pod address — `10.244.1.77` or `10.244.2.177` — and never the client's
real address. Setting LAN Networks *restricts* what counts as local, and the three
recorded CIDRs are client VLANs that cannot contain a pod address. Every local session
therefore fell outside LAN Networks and Plex treated it as remote, applying remote-stream
quality treatment to household playback. That is the stutter.

The fix is to add the pod network:

```
192.168.10.0/24,192.168.12.0/24,192.168.20.0/24,10.244.0.0/16
```

Confirmed working: local phone sessions now register as **LAN** in Tautulli.

**Do not add `192.168.90.0/24`.** The cluster VLAN looks like the natural companion and is
a trap. Remote clients currently arrive with their real public address because
`externalTrafficPolicy: Local` preserves it. If that were ever changed to `Cluster`,
remote clients would be SNATed to node addresses inside `192.168.90.0/24`, and listing
that range here would classify **Internet clients as local**, exempting them from every
remote limit. The pod CIDR carries no equivalent risk, because nothing outside the
cluster can source from it.

This was not caused by any change in this design. The Plex pod had zero restarts and had
been running since 2026-08-02; the misclassification dates from whenever the internal
Envoy became the local path. It went unnoticed because nothing measured it until the
0.1.1 precondition forced the question.

**It does correct a claim in the decision.** §6 says `externalTrafficPolicy: Local` keeps
Plex's `LAN Networks` bandwidth classification correct. That holds for remote clients
arriving through the DNAT, whose real addresses are preserved. It was never true for
local clients arriving through Envoy, whose addresses are the proxy's.

**Order matters because of this.** Fix LAN Networks before running the baseline matrix.
Rows 4 and 5 measure bitrate through the internal Envoy; baselining them while throttled
would record the stutter as normal and then "prove" no regression against a broken
reference.

Secure connections is recorded because §6 forbids changing it here; if it drifts later
you will want to know what it was. The custom URL is recorded verbatim because step 3.1
changes it and the exact prior value matters if you roll back.

### 0.2 UniFi preflight

1. Confirm UPnP and NAT-PMP are **disabled**. This is §7.2 hard gate 5 — if Plex can
   open its own mapping, exposure is not under your control.
2. Inventory WAN forwards. Confirm no Plex rule and no TCP `32400` rule exists.
3. Do not record the live WAN address in this repository or any other public artifact.

### 0.3 Cluster-side baseline

```bash
mise exec -- just kube plex-verify
```

Confirms Plex is healthy internally and `192.168.90.31` is allocated. Then capture the
alert baseline, so a later firing is distinguishable from one already firing:

```bash
mise exec -- kubectl --kubeconfig .kube/config --context homelab-diagnostic \
  --namespace monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

With that open, all five `plex-remote-access` rules should read `inactive`, and the two
`absent()` rules must be `inactive` — if either is firing, the detector is blind and
stage 3 does not start.

### 0.4 The client matrix

Run every row. Force client rediscovery before each one. Capture measurements after 60
seconds of sustained playback, not at start.

| # | Client / action | Gate | Baseline result |
|---|---|---|---|
| 1 | Plexamp switches to Sonos without AirPlay and plays | Primary objective | **fail** — expected at baseline |
| 2 | Apple TV local playback uses the internal Envoy | Hard | pass — Direct Play above 2 Mbps |
| 3 | Native Sonos plays the Plex library | Hard | **not tested** — see 0.4.2 |
| 4 | Plexamp "This device" uses internal Envoy, not Relay, above 2 Mbps | Hard | pass |
| 5 | Plex iOS local 4K Direct Play at high bitrate through internal Envoy | Hard | pass |
| 6 | Plex Web switches to Sonos | Soft | fail |
| 7 | Off-site cellular reaches Plex above 2 Mbps | Soft | fail — expected, no DNAT at baseline |
| 8 | Relay serves separately when direct access is unavailable | Soft | **inconclusive** — see 0.4.1 |
| 9 | Tautulli continues recording sessions | Hard | pass |
| 10 | Homepage Plex widget remains populated | Hard | pass |
| 11 | Gatus Plex endpoint remains green | Hard | pass |

Captured 2026-08-12, before any stage 3 change. Row 1 failing is the reason this design
exists.

### 0.4.1 Row 8 is inconclusive, not a failure

Off-site cellular with Tailscale disabled did not load the library, which reads as Relay
being dead. It is not. `just kube plex-relay-status` shows the full successful lifecycle
during that window:

```
startRelay  →  [PlexRelay] Authenticated to <relay>  →  Allocated port … → 127.0.0.1:32401
```

The boundary table in the superseded runbook maps that exactly: an allocated port with a
client that cannot browse points at **client or account authorization**, not the relay
path and not the cluster. Recorded as inconclusive so that a later reader does not treat
"Relay is broken" as an established fact, and so §8's rollback — which assumes Relay
remains as the fallback — is not quietly undermined by a conclusion the evidence does not
support.

Retest with the client fully signed out and back in before recording anything stronger.

### 0.4.2 Row 3 was never run

An earlier version of this table recorded row 3 as `pass`, and summarised the table as
"every hard row passes". Neither was true: row 3 was reported as working without being
exercised, and the operator corrected that during stage 3. Both statements are withdrawn.

This matters beyond bookkeeping. Row 3 was in fact **failing** at baseline, for a cause
unrelated to this design — see stage 4's results. A row recorded as passing on no
measurement concealed a months-old outage, and stage 4's comparison basis was one row
weaker than it claimed.

Record a row as `not tested` when it was not tested. It costs nothing and it stays true.

Row 1 is expected to **fail** at baseline. That failure is the reason this design
exists. Rows 7 and 8 will reflect Relay, since no direct path exists yet.

**Phase 0 passes** when every row is recorded, the settings table is filled in, UniFi
preflight holds, and all five alerts read `inactive`.

## Stage 3 — exposure

Three changes, in this order. The order is not arbitrary.

### 3.1 Fix the custom server access URL first

Set it to exactly one URL — the `plex.direct` name for the Plex `LoadBalancer` address:

```
https://<lb-address-with-dashes>.<certificate-uuid>.plex.direct:32400
```

`<certificate-uuid>` is the server's `CertificateUUID` from `Preferences.xml`, which is
also the wildcard in the certificate Plex serves. `<lb-address-with-dashes>` is the
`LoadBalancer` address with dots replaced by dashes. Plex's DNS resolves that name to the
address it encodes, and the wildcard certificate covers it, so local clients get a direct,
valid-TLS path with no extra hop.

**Do not list the internal Envoy hostname here.** An earlier version of this step
instructed exactly that, and it is why row 1 failed through all of stage 3. Plex's cloud
handed the Envoy URL to the Sonos speaker for the Plexamp cast; that hostname resolves to
the internal Gateway VIP, which the Sonos VLAN has no route to, so the cast never started.
Native Sonos playback worked throughout because it received a `plex.direct` URL instead.
Removing the Envoy URL fixed row 1 immediately and regressed nothing — row 2 still reports
full Direct Play without it.

**The port is not optional and this step comes first.** Plex applies the Remote Access
port to any custom URL that omits one, so a portless entry gets `:32400` appended to
whatever host it names. Setting this before the manual public port means no wrong value
is ever published, and clients cache failures.

### 3.2 Create the UniFi DNAT

One rule, and no more:

| Field | Value |
|---|---|
| Protocol | TCP only |
| External port | `32400` |
| Forward to | `192.168.90.31` |
| Internal port | `32400` |
| Logging | enable if available — §7.1 names UniFi syslog as an immediately available measure |

Create it **before** setting Plex's manual public port. This way the path works before
Plex begins advertising it. The reverse order advertises a connection that cannot be
reached, and clients cache failures.

### 3.3 Set Plex's manual public port

Enable "Manually specify public port" and set it to `32400`, matching the rule.

Change nothing else. Secure connections stays at the value recorded in 0.1. Unauthenticated
networks stays empty. The default port is used deliberately: a high random port is cheap
obscurity and a reasonable later hardening step, but it is an untested variable in an
experiment whose purpose is establishing whether Sonos works.

## Reading the stage 3 gate

**The gate is that Plex publishes a `*.plex.direct` remote connection.** It is not
whether Plex reports itself reachable.

That distinction is load-bearing. §3 of the decision records Sonos playing while Plex's
Remote Access state read `Mapped - Not Published (Not Reachable)`. Reachability state
demonstrably does not prevent Plex from constructing a media URL, so it cannot serve as
the gate. What §2.2 identifies as the mechanism is the connection's *name*, and whether
Plex now publishes a `*.plex.direct` connection is directly observable in its published
resource list.

Record the Remote Access state anyway. It is a useful indicator — it is the observable
that failed throughout the Envoy experiment — but it does not gate the stage.

The Plex log lines that diagnosed the original Sonos failure will answer the central
hypothesis within minutes: whether Sonos prefers the published `plex.direct` connection
over the retained custom URL. That hypothesis has never been falsified, and this is the
first opportunity to do so.

## What to watch during the window

Detection is live and will react to real traffic. Expect the alerts to be quiet; if one
fires, it is telling you something.

Attribution is deliberately absent from Prometheus. For source addresses:

```bash
mise exec -- just kube plex-network-observe 600
```

Read [the detection runbook](plex-remote-access-detection.md) for what each alert means
and how to respond. Note the timing characteristic observed during stage C: alerts arrive
later than their `for:` durations suggest, because the rate window must fill first.

## Stage 4 — acceptance

Repeat the full matrix from 0.4 against the baseline you recorded. Force rediscovery
before every row.

**Acceptance requires row 1 to pass and hard rows 2-5 and 9-11 to match baseline.** Rows
6-8 are soft and do not gate.

Also run external negative scans from off-network:

1. Only `32400`/TCP answers. No other port is reachable.
2. No AAAA record exists for any published Plex name — §7.2 hard gate 4.
3. Plex has not opened any additional mapping via UPnP or NAT-PMP — re-check the UniFi
   forward inventory against 0.2.

**Row 1 failing is a failed experiment**, not a partial success. §7.2 hard gate 2 makes
it an immediate revert.

### Stage 4 results — 2026-08-12, ACCEPTED

| # | Gate | Baseline | Stage 4 | |
|---|---|---|---|---|
| 1 | Plexamp → Sonos | fail | **pass** | primary objective |
| 2 | Apple TV local | pass | pass | full Direct Play |
| 3 | Native Sonos | *not tested* | **pass** | was broken at baseline |
| 4 | Plexamp "This device" | pass | pass | above 2 Mbps |
| 5 | Plex iOS local 4K | pass | pass | |
| 6 | Plex Web → Sonos | fail | **pass** | soft |
| 7 | Off-site cellular | fail | direct, not Relay | soft; client-capped, see below |
| 8 | Relay serves separately | inconclusive | *not tested* | soft; deliberately skipped |
| 9 | Tautulli | pass | pass | |
| 10 | Homepage widget | pass | pass | |
| 11 | Gatus endpoint | pass | pass | |

**Accepted.** Row 1 passes and every hard row matches or exceeds baseline. Rows 1, 3 and
6 moved from failing to passing. No hard row regressed.

Row 7 reached Plex over the DNAT, not Relay — confirmed by the relay process moving only
24 bytes/sec (keepalive) and being torn down sixteen minutes before the measurement. It
is recorded as direct rather than `pass` because the iOS client's own remote-quality
setting capped the stream at 2 Mbps, so the "above 2 Mbps" threshold was never exercised.
Raise the client's remote quality before claiming that row.

Row 8 was skipped by decision: testing it requires disabling the DNAT, which interrupts
remote access for the household. It is recorded as `not tested`, not `inconclusive`.

External negative scans, all three satisfied:

| Gate | Method | Result |
|---|---|---|
| Only `32400`/TCP reachable | `nmap` from off-network cellular | `32400` open, 1027 filtered |
| No AAAA on published names | `dig AAAA` via public resolver | none on any name |
| No UPnP/NAT-PMP mapping | Plex prefs + log | manual mapping only |

Scan validity matters here: a first attempt run from inside the LAN reported `22`, `80`,
`443`, `8080` and `8443` open — the gateway's own management ports, reached over the LAN
interface. Sub-millisecond latency and `conn-refused` rather than `filtered` are the tells.
**A negative scan is only evidence when it originates off-network.**

### Stage 4 findings — two causes, both outside the cluster

Row 1 and row 3 shared a cause and needed no repository change:

1. **A UniFi rule pointed at a retired host.** The rule granting the Sonos VLAN access to
   Plex still named the pre-migration Mac mini. The speakers had been unable to reach
   Plex since Plex moved into the cluster — which is why row 3 was failing, unnoticed,
   behind an unmeasured `pass`. Repointed at the Plex `LoadBalancer` address, scoped to
   `32400`/TCP.
2. **A stale custom access URL.** Plex still advertised the internal Envoy hostname, which
   resolves to the internal gateway address — one the Sonos VLAN has no route to. Plex's
   cloud handed the speaker *that* URL for the Plexamp cast, so the cast never started
   while native playback, which received a `plex.direct` URL, worked. Removing it left
   only the `plex.direct` connection and row 1 passed immediately.

**The design's central assumption was backwards.** §6 assumed Sonos would prefer the
published `plex.direct` connection over the retained custom URL. The cast preferred the
custom URL, and that preference was the defect. Treat client connection choice as
something to observe, not predict: query the client for the URL it actually holds.

### Operator-side state this depends on

None of the following lives in Git. All of it is load-bearing.

| Where | Setting | Why |
|---|---|---|
| Plex → Network | Custom access URLs contain **only** the `plex.direct` URL | An Envoy URL here breaks the Sonos cast |
| UniFi | Sonos VLAN → Plex `LoadBalancer` address, `32400`/TCP | Speakers fetch audio directly |
| UniFi | UPnP and NAT-PMP disabled | Plex probes hourly and will map a port if permitted |
| Pi-hole | `plex.direct` private-IP answers must resolve | Rebind protection otherwise strips them |

The Pi-hole entry is the fragile one. A per-name A record pins the server's certificate
UUID and the address; `rebind-domain-ok=/plex.direct/` achieves the same result without
pinning either, and survives certificate regeneration and address changes.

## Hard gates — any one triggers immediate revert

1. Any internal consumer regresses, at any stage.
2. Row 1 fails at stage 4.
3. Any WAN port other than `32400`/TCP is reachable.
4. An AAAA record exists for any published Plex name.
5. Plex opens its own port via UPnP or NAT-PMP.

## Rollback

**Rollback removes exposure, not containment.** Local access never depended on any of
this and is unaffected by steps 1, 3, and 4.

| # | Action | Effect |
|---|---|---|
| 1 | Remove the single UniFi DNAT | Blocks new connections in seconds. Established sessions may survive |
| 2 | Restart the Plex Deployment | Evicts established sessions. Interrupts local playback too |
| 3 | Clear Plex's manually specified public port | Plex stops advertising a direct remote connection |
| 4 | Revert the Service and CNP change in Git | Only when abandoning the design |

**Step 1 is not complete rollback.** Deleting a forwarding rule blocks new connections
but does not necessarily drop sessions UniFi already holds in conntrack.

**Step 2 is deliberately not part of ordinary rollback.** The config PVC is
`ReadWriteOncePod` under a `Recreate` strategy, so the old pod must terminate fully
before the new one starts — a short outage for the whole household, not a rolling
restart. Use it when eviction is the point: suspected intrusion, active attack, or
suspected Plex compromise. For an ordinary teardown, step 1 is enough and step 2 buys
nothing, because there is nobody to evict.

A router-side conntrack flush would be more surgical. None is selected here: no
repository recipe performs one, and an unrehearsed manual gateway operation is a poor
thing to invent during the incident that needs it.

## After a clean run

Stage 5 removes the superseded public plane, and is gated on stage 4 passing — the old
machinery is the fallback position until the replacement is proven. It comes out through
two different mechanisms because it lives in two places.

**Flux-managed — done.** The public Gateway and its `networking-public` namespace,
certificate, EnvoyProxy and dedicated MetalLB pool at `.39` were removed once stage 4 was
accepted, together with the `plex-public` route, the matching network-policy consumer, and
the namespace label that admitted it. The DDNS drift exporter followed in its own change.
`192.168.90.39` is unallocated.

**External state — operator actions, none reachable from Git.** In order: delete the
public Cloudflare A record, disable the UniFi DDNS entry, then revoke the scoped token
**last**. Revoking first leaves the updater failing against a record it can no longer
correct. The drift exporter that used to watch for exactly that condition is gone, so
nothing will alert on a half-finished teardown — complete all three in one sitting.

Permanence is a separate decision and is not implied by a clean run.
