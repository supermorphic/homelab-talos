# Plex direct remote access — exposure runbook

Procedure for stages 3 and 4 of
[Plex direct remote access — decision](../decisions/2026-08-11-plex-direct-remote-access.md),
plus the phase-0 baseline that must be captured first.

This runbook publishes Plex to the Internet. Everything before it created capability
without exposure; this is the step that changes what the world can reach. Read
[§7.2](../decisions/2026-08-11-plex-direct-remote-access.md) before starting — four
conditions require an immediate revert, and one of them is checked before you begin.

Detection is a precondition and is already satisfied. Stage C of
[Plex remote access detection](plex-remote-access-detection.md) was exercised on
2026-08-12: a half-open scan from the LAN produced ~16.5 connections/sec, all three
detection alerts fired, and all three reached ntfy. Two forms of abuse remain
**unobserved** — repeated authentication failures and bandwidth saturation — and the
decision's §2 says stage 3 proceeds with that stated, or it does not proceed.

## Current state

Stages 1 and 2 are merged and live:

- Plex Service is `LoadBalancer` at `192.168.90.31`, `externalTrafficPolicy: Local`.
- The Plex CiliumNetworkPolicy admits `world` on TCP `32400` and nothing else.
- Hubble flow metrics are scraped; five `plex-remote-access` alerts are loaded and
  evaluating.
- **No DNAT exists.** `192.168.90.31:32400` is reachable from the LAN only, because
  Cilium's `world` entity includes LAN addresses.
- No off-cluster client has ever connected. The inbound SYN series exists only from the
  stage C exercise.

## Phase 0 — baseline, before touching anything

The baseline is a pre-exposure measurement. It exists so that after publishing you can
prove nothing internal regressed. **It stops being capturable the moment the DNAT
exists**, so do this first and in one sitting.

The superseded runbook's phase 0 also mapped internal Envoy pod addresses. That step is
obsolete: it existed to tell two Envoy data planes apart in logs, and this design has
only one. Remote clients now reach Plex directly and Plex records their real addresses,
because `externalTrafficPolicy: Local` preserves them.

### 0.1 Record Plex settings without changing them

| Setting | Expected now | Record |
|---|---|---|
| Remote Access | enabled | |
| Manually specify public port | **disabled** | |
| Enable Relay | enabled | |
| Secure connections | *record the current value* | |
| Allowed without auth | empty | |
| Remote streams allowed per user | `2` | |
| Custom server access URL | *record verbatim, including whether it carries a port* | |
| LAN Networks | trusted local CIDRs only | |

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
| 1 | Plexamp switches to Sonos without AirPlay and plays | Primary objective | |
| 2 | Apple TV local playback uses the internal Envoy | Hard | |
| 3 | Native Sonos plays the Plex library | Hard | |
| 4 | Plexamp "This device" uses internal Envoy, not Relay, above 2 Mbps | Hard | |
| 5 | Plex iOS local 4K Direct Play at high bitrate through internal Envoy | Hard | |
| 6 | Plex Web switches to Sonos | Soft | |
| 7 | Off-site cellular reaches Plex above 2 Mbps | Soft | |
| 8 | Relay serves separately when direct access is unavailable | Soft | |
| 9 | Tautulli continues recording sessions | Hard | |
| 10 | Homepage Plex widget remains populated | Hard | |
| 11 | Gatus Plex endpoint remains green | Hard | |

Row 1 is expected to **fail** at baseline. That failure is the reason this design
exists. Rows 7 and 8 will reflect Relay, since no direct path exists yet.

**Phase 0 passes** when every row is recorded, the settings table is filled in, UniFi
preflight holds, and all five alerts read `inactive`.

## Stage 3 — exposure

Three changes, in this order. The order is not arbitrary.

### 3.1 Fix the custom server access URL first

Set it to exactly:

```
https://plex.lab.supermorphic.com:443/
```

**The port is not optional and this step comes first.** Plex applies the Remote Access
port to any custom URL that omits one. If you set the manual public port while the URL
is portless, Plex publishes `plex.lab.supermorphic.com:32400`. Pi-hole resolves that
name to the internal Gateway VIP, which listens only on `443`, so a rediscovering local
client follows the published connection to a port nothing serves and falls back to
Relay — regressing the hard rows this design exists to protect.

Doing this before the manual port is set means the wrong value never gets published.

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
two different mechanisms because it lives in two places: the public Gateway,
`networking-public`, and the DDNS drift exporter are Flux-managed and leave through a
reviewed Git revert; the public Cloudflare A record, the UniFi DDNS entry, and the scoped
token are external state no Git change can touch, so each is an explicit operator action
with the token revocation last.

Permanence is a separate decision and is not implied by a clean run.
