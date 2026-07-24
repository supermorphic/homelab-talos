# ProtonVPN WireGuard + Gluetun (qBittorrent egress)

Reference for how qBittorrent's VPN egress is assembled: ProtonVPN WireGuard via
Gluetun's **native provider integration**, with port forwarding (NAT-PMP) and a
**Sweden** server pin. Read alongside [`phase-12-media.md`](phase-12-media.md) (the
pod design + kill-switch gate) and [`sops.md`](sops.md) (secret handling).

## How it assembles

Gluetun runs as a native sidecar in the qBittorrent Pod and owns the network namespace;
qBittorrent shares it and cannot administer routes. Gluetun builds the WireGuard tunnel
itself using **only the private key** plus its own embedded ProtonVPN server database:

```yaml
# gluetun env (kubernetes/apps/media/qbittorrent/app/values.yaml)
VPN_SERVICE_PROVIDER: protonvpn
VPN_TYPE: wireguard
WIREGUARD_PRIVATE_KEY: <from the SOPS secret `protonvpn`>
SERVER_COUNTRIES: Sweden        # server pin (see below)
VPN_PORT_FORWARDING: "on"       # NAT-PMP dynamic forwarded port
PORT_FORWARD_ONLY: "on"         # only port-forwarding-capable (P2P) servers
```

**The generated `.conf` is never loaded.** With the native ProtonVPN provider, Gluetun
does not read a WireGuard config file — it retains only the `PrivateKey` and
**independently selects a Proton endpoint** using its `SERVER_*` filters. The ProtonVPN
private key is **account-scoped** ("works with all Proton VPN servers" per Gluetun's
docs), so the specific server you happened to pick when generating the key on Proton's
website is irrelevant to the endpoint Gluetun connects to.

### Do NOT mount `wg0.conf`

Gluetun *also* supports mounting a full config at `/gluetun/wireguard/wg0.conf`, and in
that mode the file's `Endpoint`/`PublicKey` **take precedence over the environment
variables** and would override Gluetun's server selection. This deployment must **not**
mount that file — server selection stays under our declarative `SERVER_*` control. (The
only file we mount into Gluetun is `/gluetun/auth/config.toml`, the control-server auth
roles — unrelated to WireGuard.)

### Which `.conf` fields are used

| Field in the downloaded `.conf` | Used by Gluetun? |
| --- | --- |
| `PrivateKey` | **Yes — the only value we extract** |
| `Address`, `DNS`, `PublicKey`, `Endpoint`, `AllowedIPs` | No — Gluetun derives these itself |

## Generating the credential on the Proton website

The **server you select is irrelevant** to Gluetun's eventual endpoint, but the
**credential must be NAT-PMP-enabled** — that is what makes port forwarding work.

1. Proton account → **Downloads → WireGuard configuration**.
2. Set the generation options (these *do* matter — they are baked into the credential):
   - **NetShield:** No filter
   - **Moderate NAT:** Off
   - **NAT-PMP (Port Forwarding):** **On**  ← required for port forwarding
   - **VPN Accelerator:** On
3. Pick any **P2P / port-forwarding-capable Swedish** server (choice is cosmetic for
   Gluetun; just use a valid one so Proton issues a NAT-PMP credential).
4. Generate, then copy **only** the `[Interface] PrivateKey`. Do not commit or mount the
   file.

Feed the key to the guarded recipe (in your shell, with your age key loaded):

```bash
read -rs WIREGUARD_PRIVATE_KEY; export WIREGUARD_PRIVATE_KEY   # paste PrivateKey, Enter
export PROTONVPN_SECRETS_CONFIRM='write:media:protonvpn:sops'
mise exec -- just repo protonvpn-secrets
git add kubernetes/apps/media/qbittorrent/app/protonvpn.sops.yaml
git commit -m "Add SOPS protonvpn secret for qBittorrent+Gluetun" && git push
```

`just repo protonvpn-secrets` also generates the Gluetun control-server API key and bakes
it into the encrypted `config.toml`. Secret handling is leak-safe by construction: the key
is passed via environment (never a CLI arg or `echo`), the plaintext intermediate lives
only in a `umask 077` tempdir cleaned by an `EXIT` trap, and the recipe asserts neither the
key nor the apikey appears in the ciphertext before moving only the encrypted file into
place.

## Server pin: country, not hostname

`SERVER_COUNTRIES: Sweden` encodes the real requirement — the **exit must be in Sweden** —
while letting Gluetun fail over to another Swedish port-forwarding server if one is
retired. An exact-hostname pin (`SERVER_HOSTNAMES`) is brittle: Gluetun's docs warn that if
a pinned hostname disappears from its server data, the container stops working until the
filter is changed. To see current options: `gluetun` can list servers, or check Gluetun's
`servers.json`. Change the pin by editing `SERVER_COUNTRIES` in `values.yaml` (a normal PR)
— never by mounting a `.conf`.

## Port forwarding

`VPN_PORT_FORWARDING=on` makes Gluetun acquire a forwarded port from Proton via NAT-PMP.
On each (re)connect Gluetun runs `VPN_PORT_FORWARDING_UP_COMMAND` to push the port into
qBittorrent (`listen_port`, bind to `tun0`) and `_DOWN_COMMAND` to reset it on
disconnect. The port is dynamic — do not hard-code it anywhere.

## Why WireGuard (we evaluated both)

We considered **OpenVPN** and **WireGuard**; both meet the hard requirements (Sweden pin,
port forwarding, fail-closed kill switch) in Gluetun. OpenVPN uses long-lived account
credentials (`OPENVPN_USER`+`+pmp` / `OPENVPN_PASSWORD`) with **no expiry**, so its only
real advantage is avoiding the annual renewal below.

We chose **WireGuard** deliberately:

| | WireGuard (chosen) | OpenVPN |
| --- | --- | --- |
| Protocol | modern default, in-kernel | legacy, userspace crypto |
| Throughput / CPU | faster, lighter on the NUCs | slower, higher CPU |
| Reconnect | near-instant | slower renegotiation → longer stalls |
| Credential | account-scoped key, **~yearly Extend** | static, no expiry |

Rationale: WireGuard is the modern default, reconnects near-instantly (which matters for
the kill-switch recovery path and for tunnel flaps), and is faster and lighter on the NUC
hardware. The **one** downside — the annual manual credential Extend (below) — is a
~2-minute chore that is fully **mitigated**: a lapse is fail-closed (downloads pause, no
leak) and is now caught by a reactive critical alert (see "Monitoring the expiration"). We
judged that acceptable versus OpenVPN's ongoing performance/reconnect cost. Switching to
OpenVPN later is a small change (swap `VPN_TYPE`, the credentials, and the secrets recipe)
if the renewal ever proves more trouble than the perf is worth.

## Annual credential renewal — MANUAL, required

ProtonVPN WireGuard credentials **expire (~1 year)**. Proton exposes an **Extend** action
in the dashboard; there is **no API** for it in this flow, so renewal is a manual website
click.

**What happens if it lapses:** the WireGuard handshake fails → the tunnel never comes up →
Gluetun's firewall kill switch blocks *all* qBittorrent egress (fail-closed, by design).
Downloads stall but nothing leaks. It is a visible outage, not a silent one.

**Renewal runbook:**
1. Proton dashboard → **Extend** the WireGuard configuration before the expiry date.
2. **If Extend keeps the same key** (typical): nothing to change in-cluster.
3. **If Proton issues a new key** (regenerate): rotate the secret — re-run
   `just repo protonvpn-secrets` with the new `PrivateKey`, commit the updated
   `protonvpn.sops.yaml`, and let Flux reconcile (or `just kube qbittorrent-verify`).

## Monitoring the expiration — options

**Can an Alertmanager rule auto-read the expiry date? No.** The expiry is known only to
Proton and to you at generation time. The WireGuard private key carries no embedded date,
Gluetun has no metric for it, and there is no Proton API to query in this flow — so
**nothing in the cluster can autonomously discover the renewal date**. Given that, three
realistic approaches (recommend #1 + #3):

1. **Reactive critical alerts — IMPLEMENTED (Phase 12).** Alert on the *symptoms*: the
   Gluetun control server's no-auth health role (`GET /v1/vpn/status`) reports the VPN not
   `running` for > 5 min → **critical**. This catches an expired credential *and every
   other failure that changes Gluetun's status (Proton outage, node issue, config
   regression). Wiring: a **Gatus** `Media/qbittorrent-vpn`
   check probes the in-cluster control server (ClusterIP `qbittorrent-gluetun-control`,
   never LAN-exposed, never logs the apikey) with body condition `status == running`;
   Gatus exports `gatus_results_endpoint_success`, and the `QbittorrentVpnDown`
   `PrometheusRule` (severity `critical`) fires on it. The partial failure where status
   remains `running` but the forwarded port is missing is handled by the deliberately-slow
   Gluetun liveness fallback; `QbittorrentGluetunRestartLoop` becomes critical after two
   container restarts in 15m if that fallback does not recover. Downside: these alerts fire
   *after* expiry/failure, not before. *Alertmanager has no receiver yet — see below.*

2. **Proactive expiry alert (optional, semi-manual).** Store the known renewal date as a
   value you control — e.g. a small static metric (`protonvpn_credential_expiry_timestamp`)
   sourced from a ConfigMap — and a `PrometheusRule` that warns when
   `time() > expiry - 14d`. Gives a two-week heads-up, but **you must update the date each
   year at renewal**, so it is not fully automatic.

3. **External reminder (simplest proactive nudge).** Since Extend is a manual website
   click anyway, a yearly calendar/reminder-app entry (set a few weeks before expiry) is
   the pragmatic proactive control. Pair it with #1 so a missed reminder still surfaces as
   a critical in-cluster alert.

**Bottom line:** use an external reminder for the *proactive* nudge and the in-cluster
reactive VPN-down critical alert (Phase 14) as the *safety net*. The optional #2 metric is
only worth it if you'd rather keep the date in Git than in a reminder app.
