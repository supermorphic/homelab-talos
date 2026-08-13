# Plex public Envoy, Relay, and Sonos operator runbook

> **SUPERSEDED — do not follow.** The public Envoy experiment this runbook drives was
> superseded by
> [Plex direct remote access](../decisions/2026-08-11-plex-direct-remote-access.md), and
> the public Gateway, its address pool, and every `plex-public` recipe and script named
> below have since been removed from the repository. The commands here will not run.
> Kept as the historical record of the experiment. For current operation see
> [the direct remote access runbook](plex-direct-remote-access.md).

This runbook executes the reversible experiment approved by the
[Plex public Envoy amendment](../decisions/2026-08-03-plex-public-envoy-amendment.md).
The amendment is additive to the
[Plex Relay and Sonos design](../decisions/2026-08-02-plex-relay-sonos-design.md):
the dedicated public Envoy path is now primary, while Relay remains enabled as a
best-effort fallback. The earlier identity repair, workload hardening, and Sonos
linking requirements remain in force.

The experiment publishes only `plex.lab.supermorphic.com` through a dedicated
Envoy data plane. It does not publish Plex TCP `32400`, the internal Gateway, a
wildcard route, an Envoy administrative endpoint, or IPv6. Cloudflare remains
DNS-only; do not add Cloudflare proxy or Tunnel, Tailscale Funnel, a VPS relay,
or another WAN port.

The operator performs every cluster rollout, UniFi action, Cloudflare action,
client action, and live acceptance check. Use only the guarded `mise exec -- just
…` commands shown here for cluster work; do not substitute raw `kubectl`, `flux`,
`helm`, or `talosctl`. Never record a credential, token, live WAN address, client
address, account identifier, email address, raw Hubble capture, or unrelated
request path in repository artifacts or public review systems.

## Experiment checklist

- [ ] Phase 0 — preflight and full client baseline
- [ ] Phase 1 — observed Plex consumer inventory
- [ ] Phase 2 — controller regression proof and Plex containment
- [ ] Phase 3 — dedicated public data plane, with no DNS or DNAT
- [ ] Phase 4 — deterministic DDNS proof, with WAN `443` still closed
- [ ] Phase 5 — attended activation, measurement, and rollback rehearsal
- [ ] Phase 6 — separate permanence decision

Stop immediately at any hard gate. Do not skip forward, combine phases, or treat a
later successful check as proof that an earlier gate passed.

## Invariants retained throughout

Keep these Plex settings unchanged unless a later, separately approved decision
explicitly changes them:

| Setting | Required state |
|---|---|
| Remote Access | enabled |
| Manually specify public port | disabled |
| Enable Relay | enabled |
| Secure connections | record the current value in phase 0 and do not change it |
| Allowed without auth | empty |
| Remote streams allowed per user | `2` |
| Custom server access URL | `https://plex.lab.supermorphic.com` |
| LAN Networks | only actual trusted local CIDRs |
| GDM/local discovery | enabled for local discovery; never assumed to cross VLANs |

`LAN Networks` and **Treat WAN IP as LAN Bandwidth** affect bandwidth
classification. They do not authorize traffic, bypass authentication, select a
route, or provide cross-VLAN discovery.

The reviewed workload must retain its pinned image and UID/GID `568`. Its
unprivileged init container generates a passwd entry for that identity and mounts
only the generated file read-only at `/etc/passwd`; Plex continues to own its Relay
key cache under `/config`. Never mount a raw Relay key. Keep media read-only, the
service-account token disabled, RuntimeDefault seccomp, dropped `ALL` capabilities,
and privilege escalation disabled. The Plex Cilium policy is a hard prerequisite
for public ingress.

The internal Pi-hole record, internal HTTPRoute and Gateway, wildcard certificate,
internal VIP `192.168.90.30`, and existing VLAN rules remain unchanged in every stage.
Plex's Service is now `type: LoadBalancer` at `192.168.90.31:32400`
(`docs/decisions/2026-08-11-plex-direct-remote-access.md`), for the operator's WAN DNAT;
it is not an advertised client path — Plex still advertises its pod IP, not the
LoadBalancer address, so local clients are unaffected.

## Evidence record

Use a private operator record for the attended run. Record pass/fail, timestamps,
route labels, media dispositions, bitrates, ephemeral Envoy pod addresses, and
sanitized command outcomes only. The public Envoy access log exists only in
container stdout; read it live during the experiment. Attribution can disappear
after a pod restart or log rotation because this experiment adds no aggregation,
persistent sink, or retention.

Plex's Dashboard labeling is not a routing oracle: proxied sessions appear to come
from an Envoy pod. Route attribution requires the resolved Envoy pod address plus
presence or absence in the public Envoy access log. Bitrate above 2 Mbps disproves
Relay but does not by itself distinguish the two Envoy paths.

### Map Envoy pod addresses through the read-only UI

Use the existing internal Portainer read-only Kubernetes view; this is UI inspection,
not authorization to run an unguarded cluster command.

1. Open `https://portainer.lab.supermorphic.com`, select the Kubernetes environment,
   and open its pod resource view.
2. Select namespace `envoy-gateway-system`.
3. For the internal data plane, filter pods by both exact owner labels:
   `gateway.envoyproxy.io/owning-gateway-namespace=networking` and
   `gateway.envoyproxy.io/owning-gateway-name=internal`.
4. For the public data plane, filter pods by both exact owner labels:
   `gateway.envoyproxy.io/owning-gateway-namespace=networking-public` and
   `gateway.envoyproxy.io/owning-gateway-name=public`.
5. Privately record each displayed pod IP and whether the labels map it to the
   internal or public Gateway. Do not use any Portainer mutation control and do not
   copy the mapping into a repository artifact.

Phase 0 performs only the internal filter. Phase 5 repeats the procedure immediately
before testing and records both mappings.

## Phase 0 — preflight and baseline

Make no cluster change, DNS-record change, DNAT change, or exposure change in this
phase. Its only external-control changes are creating the scoped Cloudflare token and
performing an inactive UniFi DDNS credential preflight; do not activate a DDNS entry
or create its public record yet.

1. In UniFi, confirm UPnP and NAT-PMP are disabled. Inventory all WAN forwards and
   confirm that no Plex rule and no TCP `32400` rule exists. If Plex creates a
   mapping at any point, stop and remove exposure.
2. Confirm the Plex settings in the invariants table, including Remote Access
   enabled with no manual public port, the custom URL retained, and unauthenticated
   networks empty. Record the current **Secure connections** value without changing
   it.
3. Confirm that `192.168.90.39` is not assigned to a host, load balancer, DHCP
   lease/reservation, or other UniFi object. It is reserved solely for the staged
   public Gateway. Do not probe or record the live WAN address in a public artifact.
4. In Cloudflare, create a new API token limited to `Zone:DNS:Edit` for only
   `supermorphic.com`. It must be distinct from cert-manager's credential. Set an
   expiry appropriate to the attended experiment, privately record its owner and
   expiry, and document how the operator will disable the UniFi DDNS entry and
   revoke the token. Schedule periodic Cloudflare audit-log review for unexpected
   DNS changes and token use.
5. Prove UniFi DDNS accepts that scoped token. If UniFi requires a Cloudflare Global
   API Key, revoke the test token if appropriate and stop the design. A Global API
   Key is never an acceptable workaround.
6. Use the Portainer procedure above to map the current internal Envoy pod addresses,
   then run the complete client matrix below as the phase-0 baseline. Force client
   rediscovery before every row. Capture every required measurement after 60 seconds
   of sustained playback.

The phase-0 gate passes only when the scoped token is accepted, all preflight
invariants hold, and the baseline matrix is complete. There must still be no public
DNS record, public Gateway activation, or WAN DNAT.

## Phase 1 — observe the real consumer set

Use the Task 2 Hubble workflow before enforcing policy. During one bounded window,
exercise Apple TV, Plexamp, native Sonos playback, Tautulli polling, Homepage's Plex
widget, the Gatus Plex check, kubelet probes, library scanning, Relay playback, and
normal metadata activity:

```bash
mise exec -- just kube plex-network-observe 600
```

This is a read-only, bounded L3/L4 observation. Do not preserve raw output in the
repository. Build the allow-list from the observed consumer identities and the
accepted source contracts, without retaining addresses or other unique
infrastructure identifiers. A failed observation is not permission to guess or to
widen the policy.

The phase-1 gate passes only when the consumer list is authoritative and the native
Sonos path is established. Otherwise stop before containment.

## Phase 2 — containment with no public exposure

Phase 2 is two independently reviewed and merged boundaries.

After the controller-selector PR has reconciled, collect regression evidence with:

```bash
mise exec -- just kube foundation-verify
mise exec -- just kube gatus-verify
mise exec -- just kube plex-verify
```

All internal routes must serve normally and Gatus must be fully green. Revert that
phase if any internal consumer regresses; do not proceed to the Cilium policy.

After the observed Plex Cilium policy PR has reconciled, run its guarded acceptance:

```bash
PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' \
  mise exec -- just kube plex-network-policy-test
mise exec -- just kube plex-network-observe 600
```

Repeat every phase-1 consumer action, including native Sonos playback. Negative
tests 6–9 must prove that an unrelated pod cannot reach Plex, Plex cannot reach the
Kubernetes API, Plex cannot reach unapproved LAN targets on non-443 ports, and Plex
cannot reach another namespace's services. Test 10 requires every observed and
source-declared consumer to continue reaching Plex with no new denied required flow.

The phase-2 gate passes only when both review boundaries pass independently. Retain
the containment policy and security-context assertion only if they passed without
regression.

## Phase 3 — public data plane with no WAN path

This phase provisions a dedicated Gateway, VIP, certificate, and Plex-only route,
but creates neither public DNS nor a WAN rule.

Before running the bootstrap, acknowledge that requesting the dedicated certificate
will publish the exact hostname `plex.lab.supermorphic.com` in public Certificate
Transparency logs. That disclosure is permanent and cannot be rolled back by
deleting the certificate, DNS record, or Gateway. Stop here if that disclosure is
not accepted.

After the suspended public-gateway PR has merged, run only the guarded bootstrap:

```bash
PLEX_PUBLIC_PROBE_CONFIRM='test:plex-public-probe' \
PLEX_PUBLIC_GATEWAY_BOOTSTRAP_CONFIRM='bootstrap:plex-public-gateway:192.168.90.39' \
  mise exec -- just bootstrap plex-public-gateway
```

The public bootstrap establishes Gateway tests 1–5 and the log canary; it does not
run or establish containment tests 6–10. After it passes and before requesting any
public DNS, rerun the guarded containment probe explicitly:

```bash
PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' \
  mise exec -- just kube plex-network-policy-test
```

Re-exercise every phase-1 consumer, including native Sonos, Tautulli, Homepage,
Gatus, Apple TV, Plexamp, and kubelet probes. Carry the phase-1 consumer evidence
forward and re-establish test 10: every observed and source-declared consumer must
still reach Plex with no new denied required flow. The guarded containment probe plus
this consumer exercise establishes tests 6–10 independently of the public bootstrap.

All of the following must therefore be established before any public DNS or DNAT is
requested:

- the dedicated Certificate is Ready and the public Gateway is Programmed;
- negative tests 1–5 pass: no non-Plex hostname or default route, no non-443 port,
  no reachable Envoy admin endpoint, and no internal-Gateway regression;
- the explicit containment rerun proves tests 6–9, and the re-exercised phase-1
  consumer set proves test 10;
- internal foundation, Gatus, Plex, and the hard baseline consumers remain healthy;
- the access-log canary request uses the literal fake query value
  `plan-canary-not-a-secret`, the value and query string are absent from stdout,
  and source attribution remains present.

Treat any canary leak as a credential-logging failure even though the canary is not
a secret. Read the stdout result live; it is ephemeral. Failure stops the experiment
before DNS and DNAT.

## Phase 4 — deterministic DNS and DDNS proof

The operator performs these steps in Cloudflare and UniFi. Do not put the token or
observed WAN address into shell history, command output retained for review, or the
repository.

1. Create a DNS-only, unproxied A record for `plex.lab.supermorphic.com` with TTL
   `300`. Publish no AAAA record.
2. Configure UniFi DDNS for that record with the distinct phase-0 scoped token.
3. Compare the public answer from Cloudflare resolver `1.1.1.1` with the WAN IPv4
   observed through `https://api.ipify.org`. Require equality. Independently confirm
   internal Pi-hole still answers `192.168.90.30`.
4. Change only the public Cloudflare A record to the RFC 5737 test address
   `192.0.2.1`.
5. Trigger UniFi's supported force-update action, or its documented disable/enable
   cycle. Do not force a WAN lease change.
6. Require UniFi to restore the Internet-observed WAN address. If it does not,
   delete the public A record, disable DDNS, revoke the token, and stop before DNAT.
7. Bootstrap the credential-free drift exporter:

   ```bash
   PLEX_DDNS_DRIFT_BOOTSTRAP_CONFIRM='bootstrap:plex-ddns-drift' \
     mise exec -- just bootstrap plex-ddns-drift
   ```

   Require its boolean/timestamp metrics and alerting path to be green; neither the
   workload nor the evidence may log either address.
8. From a genuinely off-network connection, prove WAN TCP `443` is still closed.
   No DNAT exists yet.

The phase-4 gate passes only when the public A record follows the observed WAN
address deterministically, no AAAA exists, internal DNS is unchanged, the drift
check is healthy, and off-network TCP `443` remains closed.

## Phase 5 — attended activation and measurement

Immediately before testing, use the Portainer read-only UI procedure above to map and
privately record the current internal and public Envoy pod addresses. They are
ephemeral and must not be copied into repository artifacts. Do not substitute an
unguarded cluster command.

In UniFi, create exactly one rule: WAN TCP `443` to
`192.168.90.39:443`. Do not create a source-any/service-group rule, another-port
rule, UDP rule, direct Plex `32400` rule, or forward to the internal Gateway.

From off-network, run external negative tests 11–13: only TCP `443` is reachable,
a non-Plex hostname sent to the WAN address is not routed, and there is no AAAA or
IPv6 forwarding. Confirm the public endpoint presents the dedicated Plex-hostname
certificate rather than a Cloudflare or wildcard certificate.

Run the same matrix used for phase 0. Before every row, force rediscovery by
restarting the client or signing out and back in. For each playback row, wait for 60
seconds of sustained playback, then record these fields separately:

- network route label;
- expanded Plex Dashboard bitrate;
- video disposition: Direct Play, Direct Stream, or Transcode;
- audio disposition: Direct Play, Direct Stream, or Transcode;
- presence or absence in the live public Envoy access log; and
- observed Envoy pod address.

| # | Client/action | Gate |
|---:|---|---|
| 1 | Plexamp switches to Sonos without AirPlay and plays | Primary objective |
| 2 | Apple TV local playback uses internal Envoy | Hard |
| 3 | Native Sonos plays the Plex library as at baseline | Hard |
| 4 | Plexamp “This device” uses internal Envoy, not Relay, above 2 Mbps | Hard |
| 5 | Plex iOS local 4K Direct Plays at high bitrate through internal Envoy | Hard |
| 6 | Plex Web switches to Sonos | Soft |
| 7 | Off-site cellular appears in public Envoy log above 2 Mbps | Soft |
| 8 | Relay serves separately when direct access is unavailable | Soft |
| 9 | Tautulli continues recording sessions | Hard |
| 10 | Homepage Plex widget remains populated | Hard |
| 11 | Gatus Plex endpoint remains green | Hard |

Acceptance requires row 1 plus no regression in hard rows 2–5 and 9–11. Rows 6–8
are informative and do not gate the experiment.

Any internal regression, failed negative test, non-Plex hostname routing, reachable
WAN port other than TCP `443`, published AAAA record, Plex-created UPnP mapping, or
requirement for a Global API Key triggers the rollback below immediately. ISP
filtering, listener failure, and DNAT removal are not automatically probed from
outside; that is an accepted blind spot of this attended experiment.

Whether the matrix passes or fails, execute the rollback rehearsal before leaving
the experiment unattended. A later reactivation remains an explicit operator action.

## Rollback and connection state

Use this order:

1. Delete the single UniFi DNAT. From off-network, verify that a new TLS connection
   fails. DNAT deletion blocks new exposure but might not terminate an established
   conntrack session.
2. After confirming the DNAT is gone, flush only the public Envoy connections:

   ```bash
   PLEX_PUBLIC_CONNECTION_FLUSH_CONFIRM='flush:plex-public:dnat-removed' \
     mise exec -- just kube plex-public-connection-flush
   ```

   This guarded restart terminates possibly established stateful sessions; it does
   not restart Plex or the internal Envoy data plane.
3. Confirm internal Gatus and Plex are healthy and repeat the hard matrix rows.
4. Delete the public Cloudflare A record, disable the UniFi DDNS entry, and revoke
   the experiment token. Review the Cloudflare audit log for unexpected use. The
   missing record or disabled updater is expected to make the DDNS drift exporter
   report failure or mismatch and fire alerts. Do not silence those alerts ad hoc;
   record their expected rollback disposition in the private experiment record.
5. If abandoning the design, remove the drift exporter and public Gateway resources
   only through a reviewed Git revert. Do not patch or delete Flux-managed objects
   directly. Until that revert reconciles, treat exporter failure/mismatch alerts as
   expected rollback evidence rather than muting or editing the alert rule live.

Retain phase-2 containment only when its own gate passed. The widened controller
selector may remain when inert; do not re-touch the shared controller merely as
incident cleanup. Internal DNS, the internal Gateway and route, wildcard
certificate, and VLAN rules are never rollback targets.

## Phase 6 — decide separately

The experiment does not authorize permanent exposure. After a clean attended run,
prepare a separate decision that compares all three options: Relay, direct Plex
`32400`, and dedicated Envoy. The original decision's shared-risk comparison and the
amendment's dedicated-Envoy new-risk table are complementary; a risk absent for
Relay or direct `32400` may be not applicable rather than omitted.

The permanence record must include the complete phase-0 and phase-5 matrix,
negative-test results, rollback rehearsal, DDNS behavior, the public hostname's
irreversible CT disclosure, ephemeral-log attribution limits, backend plaintext,
the accepted lack of automated external reachability monitoring, and all observed
operational burden. Any persistent activation or monitoring change requires its own
reviewed Git change and explicit operator merge authorization.

If permanence is rejected, finish the rollback and reviewed Git revert. Relay stays
enabled as the fallback in either outcome. Direct TCP `32400` remains prohibited in
this experiment and requires a separate design and authorization.

## Relay fallback diagnostics

Relay is a separate fallback check; success here does not prove the public path,
native Sonos integration, or Sonos account linking.

1. Run the guarded Plex verification:

   ```bash
   mise exec -- just kube plex-verify
   ```

2. While initiating a remote client request, read only sanitized Relay status:

   ```bash
   mise exec -- just kube plex-relay-status
   ```

3. With Wi-Fi and Tailscale disabled, force-quit Plexamp, reopen it, browse Music,
   and play one track. Confirm Relay separately from direct access.

Interpret sanitized evidence before changing anything:

| Evidence | Boundary |
|---|---|
| no `startRelay` event | Plex account/cloud/discovery |
| child exits before authentication | local identity/key/process |
| authenticated, no allocated port | Plex Relay service/path |
| allocated port, client cannot browse | client/account/library authorization |
| native Sonos can browse, Plexamp has no Sonos entry | Sonos account linking/local discovery |

Do not print or retain Plex tokens, account identifiers, email addresses, client
addresses, or unrelated request paths. Never mount a raw Relay key, enable an
unauthenticated CIDR, or open TCP `32400` to troubleshoot Relay.

## Sonos linking and native playback

The native Sonos service and Plexamp player selection are separate gates.

For native Sonos playback, open Plex in the Sonos app, select Music under **Other
Libraries** if needed, browse, and play to a Sonos Port. This proves the cloud service
can reach and use the library; it does not prove local player discovery.

Initial Sonos linking requires Plex Pass, a full Plex account, and a supported Plex
app on the same local network as the Sonos player:

1. Temporarily connect the iPhone to an SSID mapped to VLAN 20.
2. In the regular supported Plex iOS app, open Players, select the Sonos linking
   entry, and complete Sonos OAuth with the full Plex account.
3. Return the iPhone to Main Wi-Fi. In Plexamp, confirm the intended players appear
   and play a track without AirPlay.
4. Remove the temporary VLAN-20 SSID if one was created.

Do not add broad multicast reflection or an any-to-any inter-VLAN rule because the
Players menu is empty. If same-VLAN linking succeeds but Main-VLAN control fails,
observe the precise flows first and propose only the required protocol, direction,
player group, and destination ports through a reviewed change.

## Static validation before handoff

For a runbook-only change, run the cluster-independent repository checks:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

All three are cluster-independent, static gates. Live cluster, external DNS,
certificate, UniFi, and client acceptance remains operator-run in the staged phases
above.
