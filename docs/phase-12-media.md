# Phase 12: Media Platform — VPN Download Client (qBittorrent + Gluetun)

## Status

**Complete / live (2026-07-24, PR #32 — `suspend: false`).** qBittorrent runs beside
**Gluetun** (ProtonVPN WireGuard) in one Pod, so all of qBittorrent's internet traffic
egresses through the VPN or is dropped. The **kill switch is a hard, live-tested gate**
(see `plans/media-stack-architecture-plan.md`, "VPN kill switch"); it passed on the cluster
(see "Verified findings" below) before activation. One non-blocking operational follow-up
remains open — whether a *container* (vs *pod*) restart clears the stuck DoT-DNS cycle;
tracked under "Recovery hierarchy" and covered meanwhile by the
`QbittorrentGluetunRestartLoop` alert and operator pod recreation.

An expert review of the initial design was incorporated in full (6 corrections +
credential simplification), verified against the Gluetun wiki. This doc records that
design so the hard-won decisions aren't lost.

## Confirmed facts (validated)

- `/dev/net/tun` present + world-writable (`crw-rw-rw-`) on all NUCs → Gluetun via
  `NET_ADMIN` + a `hostPath` CharDevice mount, **no privileged mode, no Talos change**.
- Pod CIDR `10.244.0.0/16`, service CIDR `10.96.0.0/12`.
- Images: Gluetun `v3.41.1`, qBittorrent `ghcr.io/home-operations/qbittorrent:5.2.3`.
- Gluetun VPN interface = `tun0`; control server on `:8000`, **auth required by default
  (≥ v3.39.1)**.

## Pod design (one app-template HelmRelease in `media`, Deployment + Recreate)

- **Gluetun native sidecar** — `initContainers.gluetun`, `restartPolicy: Always`,
  `capabilities.add: [NET_ADMIN]`, `hostPath /dev/net/tun` (CharDevice). A **startup
  probe on `GET localhost:8000/v1/vpn/status`** (the no-auth health role) so the
  qBittorrent container only starts after the tunnel + firewall are up (**fail-closed at
  boot**). Gluetun's firewall is the ongoing kill switch.
- **qBittorrent** — no `NET_ADMIN` (shares Gluetun's netns), WebUI `:8080`, config PVC
  (Longhorn RWO, Recreate, `helm.sh/resource-policy: keep`), `/data` = shared SMB PVC.
- HTTPRoute `qbittorrent.lab.supermorphic.com` (internal gateway); ClusterIP `:8080`.
  **Gluetun control server: no Service/HTTPRoute** (startup probe is localhost).
- Dedicated ServiceAccount, automount off.

## Fail-closed rationale (accurate framing)

qBittorrent holds no `NET_ADMIN`, so its unprivileged process cannot administer the
shared netns — Gluetun owns the routes/firewall. Fail-closed still *depends on* Gluetun
correctly installing and retaining those rules, which is exactly why the live failure
test (including a hard Gluetun-container kill) is mandatory, not assumed.

## Gluetun configuration (review-corrected)

- `VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`, `WIREGUARD_PRIVATE_KEY` (SOPS),
  `VPN_PORT_FORWARDING=on`, `PORT_FORWARD_ONLY=on` (restricts to port-forwarding-capable
  P2P servers), `SERVER_COUNTRIES=Sweden` (server pin). The ProtonVPN WireGuard key is
  **account-scoped** — Gluetun picks the server from its own list and ignores the
  `.conf`'s endpoint, so the pin is non-secret `values.yaml` config, not the key/`.conf`;
  Gluetun reselects within Sweden if a server is retired.
- **[C1] `FIREWALL_INPUT_PORTS=8000,8080`** — `8080` so the WebUI is reachable via the Pod
  interface (Service, Envoy, *arr, kubelet probes); `8000` so Gatus can poll the control
  server for the reactive VPN-down alert. Without these those inputs are dropped.
- **[C2] `FIREWALL_OUTBOUND_SUBNETS` — start empty, add only by test.** Cilium DNATs
  Service→Pod IP before Gluetun's egress firewall, so at most the **pod CIDR** (not the
  service CIDR) is ever needed. Observe Gluetun firewall logs during rollout; each
  permitted subnet is a deliberate non-VPN route.
- **[C3] DNS — keep Gluetun's default** (its resolver over the tunnel). qBittorrent
  resolves public trackers, not cluster Services, so do **not** set
  `DNS_KEEP_NAMESERVER=on` unless a test shows a required internal lookup.
- **[C4] Control-server auth** — mount `/gluetun/auth/config.toml` (via
  `HTTP_CONTROL_SERVER_AUTH_CONFIG_FILEPATH`) from the SOPS secret with two roles:
  `health` = `GET /v1/vpn/status` `auth=none` (startup probe + live Gatus check); `vpn_control`
  = `PUT /v1/vpn/status`, `GET /v1/publicip/ip`, `GET /v1/portforward` `auth=apikey`
  (kill-switch verify). Never a blanket `HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE=none`.
- **[C5] both `VPN_PORT_FORWARDING_UP_COMMAND` and `_DOWN_COMMAND`** — the documented
  qBittorrent pattern (`wget … /api/v2/app/setPreferences` with `{{PORT}}` +
  `{{VPN_INTERFACE}}`): UP sets `listen_port={{PORT}}`, `current_network_interface=
  {{VPN_INTERFACE}}`, `random_port:false`, `upnp:false`; DOWN resets `listen_port:0`,
  interface `lo` (needed because of a qBittorrent reconnect bug).

qBittorrent enables **"Bypass authentication for clients on localhost"**
(`WebUI\LocalHostAuth=false`) so only the in-pod Gluetun hook calls the API without
creds. **"Bypass authentication for clients in whitelisted IP subnets" stays
disabled**: whitelisting the Pod CIDR would also bypass the browser login because
internal-Gateway requests arrive from Envoy's in-cluster address. The WebUI and *arr
clients use the permanent qBittorrent credential. First-run settings persist in the
config PVC.

## Secrets

`just repo protonvpn-secrets` (clone `media-smb-secrets`) → SOPS secret `protonvpn` in
`media` with `WIREGUARD_PRIVATE_KEY` (**operator provides only the WireGuard PrivateKey**
— generated from the ProtonVPN dashboard with NAT-PMP/port-forwarding enabled) + a
recipe-generated control-server **apikey** baked into the mounted `config.toml`.

See [`protonvpn-gluetun.md`](protonvpn-gluetun.md) for the full assembly (why only the
key is used, the "don't mount `wg0.conf`" caveat, the credential-generation options),
the **annual manual credential-renewal runbook**, and the VPN-expiry monitoring options
(the live reactive critical VPN-down alert + an external yearly reminder).

## Kill-switch acceptance gate — BLOCKING (Chainsaw resilience, operator-run)

Not in `just ci`; Phase 12 was not flipped `suspend: false` or declared complete until
this gate passed live. Run it with:

```bash
CLUSTER_CHAOS_CONFIRM='chaos:qbittorrent-vpn-disconnect' \
  just test resilience qbittorrent-vpn-disconnect
```

The gate is **bulletproof by design**: the node's own WAN IP is
captured first (via a throwaway no-VPN pod) and threaded through every step as a **hard never-leak
invariant** — if qBittorrent's egress IP ever equals the home WAN IP, the gate fails
instantly. All egress probes run **from qBittorrent's own network namespace** (the `app`
container), not from Gluetun (which has VPN-infra allowances), so they measure exactly
what a torrent would see.

1. **Baseline (up, Sweden, not home):** control server reports `status=running`; public IP
   ≠ home WAN and **country == Sweden**; qBittorrent's own egress IP (probed via
   `ifconfig.me/ip`) == the VPN IP; the forwarded port is active and **applied to
   qBittorrent's `listen_port`** (proves the UP command ran); and the app container's
   **only resolver is `127.0.0.1`** (Gluetun's in-netns DoT) — a structural, cache-proof
   proof that DNS is tunneled, never sent to the node/ISP resolver.
2. **Polite stop (held down):** `PUT /v1/vpn/status {stopped}`, then over ~15s the `app`
   container must show **no IP egress** (`ifconfig.me/ip`) and **no route-level egress**
   (Cloudflare `1.1.1.1` by IP, bypassing DNS) — and never the home IP.
3. **Recovery via pod recreation (the node-reschedule path):** delete the pod; a fresh
   netns + Gluetun start must return `status=running`, **country Sweden**, egress == VPN
   IP (≠ home), and the forwarded port **reacquired and reapplied** to `listen_port`
   (DOWN→UP cycle) with no manual editing.
4. **Final:** `status=running`, egress == VPN IP, country Sweden.

On a failed/interrupted run a `trap` deletes the pod to reset to a clean state.
Precondition: first-run done (permanent WebUI credential, subnet bypass disabled, and
"Bypass authentication for localhost" enabled for the port-forward UP command).

### Verified findings (live, 2026-07-24)

- **Kill switch is solid (hard requirement, verified repeatedly):** egress only via
  ProtonVPN **Sweden** at baseline; **zero IP/route egress** while stopped; **home WAN IP
  never appeared** in baseline, polite-stop, or a real `tun0`-down interruption. DNS is
  structurally isolated — the app resolver is `127.0.0.1` (Gluetun DoT), and Gluetun's own
  resolver attempts to cluster DNS return `operation not permitted` (firewall-blocked).
- **`tun0` is stable:** the WireGuard interface name (`VPN_INTERFACE`, default `tun0`) does
  **not** change on reconnect/server rotation — confirmed present before and after a real
  interruption. Only the endpoint (transparent) and the NAT-PMP forwarded port (handled by
  the UP/DOWN commands) rotate.
- **`kubectl exec … kill -KILL 1` cannot crash the sidecar:** the kernel blocks
  same-PID-namespace SIGKILL to PID 1 (`restartCount` stays 0). Fail-closed on a real
  in-place gluetun crash is structural anyway (qBittorrent has no `NET_ADMIN`; the firewall
  DROP rules persist). The gate recovers via **pod recreation** (= node reschedule), which
  is deterministic and recovered to Sweden in seconds.
- **In-place recovery can get stuck (reproducible):** after a real `tun0`-down interruption
  Gluetun reconnects the **data plane** (app egresses via a Sweden VPN IP — no leak) but its
  **DoT-DNS healthcheck cycles** (`lookup cloudflare.com/github.com: i/o timeout`), so it
  stays `status=running` with an **empty public IP** and never reacquires the forwarded
  port. Same pod UID, `restartCount` 0 — a purely in-process loop. A **pod recreation**
  (fresh process + netns) recovers cleanly; container-only restart remains unvalidated.
  (Rapid repeated reconnects also trip **ProtonVPN reconnect rate-limiting** — space out
  live tests.)

### Recovery hierarchy + the k8s liveness fallback

Per the validated design, recovery escalates: (1) Gluetun detects the failed tunnel →
(2) firewall stays fail-closed → (3) Gluetun reconnects in place (`HEALTH_RESTART_VPN=on`,
default; **encrypted DoT retained — do not set `DOT=off`**) → (4) forwarded port reacquired
+ propagated → (5) **k8s restarts the container only when in-place recovery stays stuck**.
Step 5 is a **deliberately-slow gluetun liveness probe** (exec: control-server
`status=running` **and** a nonzero forwarded port; ~5 min
`failureThreshold*periodSeconds` so a normal flap never trips it). The forwarded port is
the direct health signal: Gluetun's public-IP discovery is a one-shot metadata fetch and
can remain empty on an otherwise working tunnel. Only an explicit `status=stopped` reports
healthy; query failures and unknown/transitional/crashed states fail.

**Open validation:** whether a *container* restart (same netns, fresh gluetun process)
clears the DoT cycle, or whether only a *pod* restart (fresh netns) does. Confirm live when
ProtonVPN is calm; if a container restart is insufficient, escalate step 5 to pod
recreation. `QbittorrentGluetunRestartLoop` fires after two container restarts in 15m so
this failure is not silent; manual/operator pod recreation is the recovery meanwhile.

## Observability (reactive VPN-down reporting)

Health is surfaced where each tool fits best; the tunnel status is read from Gluetun's
control server, exposed **in-cluster only** via ClusterIP `qbittorrent-gluetun-control`
(no HTTPRoute, no LoadBalancer). `FIREWALL_INPUT_PORTS` admits `8000` alongside `8080`;
the health route (`GET /v1/vpn/status`) is no-auth, mutating routes stay apikey-gated.

- **Gatus (primary status):** a `Media`-group endpoint `qbittorrent-vpn` probes the
  control server with a **body condition `[BODY].status == running`** (the control server
  answers 200 even while the tunnel is down, so status-code alone is insufficient).
- **Prometheus / Alertmanager (critical alerts):** `PrometheusRule` `qbittorrent-vpn` →
  **`QbittorrentVpnDown` (severity: critical)** fires on `gatus_results_endpoint_success{
  name="qbittorrent-vpn"} == 0` for 5m when status is not running.
  **`QbittorrentGluetunRestartLoop` (severity: critical)** fires after two Gluetun container
  restarts in 15m, covering the `status=running`/no-forwarded-port state if container-only
  recovery repeats. `QbittorrentVpnProbeMissing` warns if the Gatus metric disappears.
  *Alertmanager has no receiver configured yet — alerts fire and are visible in
  Alertmanager/Prometheus/Grafana; delivery to a phone/email channel is a follow-up (needs
  a channel + secret).*
- **Grafana:** the `gatus_results_endpoint_success` series and the firing alert are
  queryable/visible without a bespoke dashboard.
- **Homepage:** the qBittorrent tile (pod-selector) shows pod health; the optional
  gethomepage Gluetun widget (public IP / country / forwarded port) is deferred because it
  requires exposing the control-server apikey to Homepage.

## Completed rollout sequence

- **12-1** delivered qBittorrent+Gluetun manifests (initially staged `suspend: true`) + `just repo
  protonvpn-secrets` + `qbittorrent-validate` (→ `just ci`) + `qbittorrent-verify` +
  the qBittorrent VPN-disconnect resilience scenario + `bootstrap qbittorrent`.
- The operator rollout completed: `just repo protonvpn-secrets` → merge → `just
  bootstrap qbittorrent` → `just kube qbittorrent-verify` → the predecessor
  kill-switch proof (now `just test resilience qbittorrent-vpn-disconnect`) →
  durable `suspend: false` merged in PR #32.

## First-run / manual settings

qBittorrent WebUI credential, localhost-auth bypass toggle, disabled subnet-auth bypass,
categories, and save paths (`/data/downloads/...`) are first-run settings in the config
PVC. The credential is kept in the password manager and copied to Homepage only through
the operator-generated `homepage-qbittorrent.sops.yaml`. Sonarr/Radarr (Phase 13) point
their download client at `http://qbittorrent.media.svc.cluster.local:8080` and enter the
same credential in their retained application configuration. See
[`arr-stack-startup.md`](arr-stack-startup.md) for the exact procedure.
