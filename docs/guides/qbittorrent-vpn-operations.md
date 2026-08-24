# Operate qBittorrent VPN egress

This guide covers qBittorrent's Proton VPN connection, the Gluetun sidecar that enforces
it, dynamic port forwarding, credential maintenance, verification, and recovery. See
[SOPS secret operations](sops-secret-operations.md) for the repository-wide credential rules and
[Media automation setup](media-automation-setup.md) for qBittorrent's WebUI and
greenfield-PVC workflow.

## VPN flow and fail-closed behavior

qBittorrent and Gluetun run in the same Kubernetes Pod and share one network namespace.
Only Gluetun can administer that namespace:

```text
qBittorrent
   ↓ shares the Pod network namespace
Gluetun
   ↓ owns routes, firewall, and DNS
Proton VPN WireGuard tunnel
   ↓
Swedish P2P endpoint with port forwarding
   ↓
Internet
```

Gluetun has `NET_ADMIN` and `/dev/net/tun`. qBittorrent runs as UID/GID `568`, drops all
Linux capabilities, and cannot change routes or disable the VPN firewall. The Gluetun
startup probe prevents qBittorrent from starting until the tunnel and firewall are
ready.

The safety result is deliberate:

```text
VPN healthy
→ qBittorrent egresses through Gluetun and Proton

VPN unavailable
→ Gluetun blocks qBittorrent Internet egress
→ downloads stop
→ traffic does not fall back to the home WAN
```

Gluetun's firewall is the egress kill switch. Kubernetes routing and the internal
qBittorrent HTTPRoute provide application access; they do not create an alternate
Internet path around the shared Pod network namespace.

## Ownership and security boundaries

Git and SOPS own:

- the encrypted Proton WireGuard private key;
- Gluetun's provider, country, firewall, DNS, control-server, and port-forward settings;
- the qBittorrent integration hooks;
- the Secret revision stamped into the Pod template;
- monitoring rules and repository verification code.

Proton owns whether the credential remains valid and which P2P endpoints are available.
Gluetun selects an endpoint, establishes WireGuard, applies its firewall and DNS path,
obtains the forwarded port, and updates qBittorrent. qBittorrent consumes that network
path and the current forwarded port.

Only the Proton WireGuard `PrivateKey` is retained from the generated configuration. The
guarded Secret writer also creates a separate API key for Gluetun's control server. The
control server is exposed only through a ClusterIP Service. Gatus may read only
`GET /v1/vpn/status` without authentication; the other configured control routes require
the API key.

Never mount Proton's generated `wg0.conf`. Gluetun supports
`/gluetun/wireguard/wg0.conf`, but fields in that file take precedence over environment
settings. Mounting it would move endpoint and public-key selection outside the declared
native-provider configuration and could defeat the Sweden/P2P failover model.

## When operator action is needed

| Situation | Action |
| --- | --- |
| Normal operation | None. Gluetun reconnects automatically, and monitoring watches the VPN path. |
| qBittorrent or Gluetun source change | Run source validation, publish through Git, and run live verification after Flux reconciles. |
| Proton credential approaching its displayed expiry | Use Proton's current account workflow to extend the existing credential when available. |
| Proton supplies a new private key | Rotate the encrypted Secret and rollout stamp through Git, then complete rotation acceptance. |
| One Swedish endpoint disappears | Normally none. Gluetun may choose another compatible Swedish endpoint. |
| VPN or port forwarding remains unhealthy | Diagnose the Gluetun/VPN path. Keep the kill switch in place and follow the recovery rules below. |
| A rotation fails while the previous credential is still valid | Revert the rotation through reviewed Git. |

## Command effects and authority

The confirmation string on a command is an execution guard. Authority comes from
`AGENTS.md`, the command's required credentials, and whether the command changes Git or
live state.

| Command | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just repo protonvpn-secrets` | Writes the SOPS-encrypted Proton/Gluetun Secret, generates a new control-server API key, and updates the Pod-template Secret revision. | Changes two tracked files. Operator-run because it needs the plaintext Proton private key and the operator-held SOPS age identity. |
| `mise exec -- just kube qbittorrent-validate` | Checks source wiring, encrypted Secret metadata, rollout-stamp parity, Gluetun safety settings, monitoring, and the pinned Helm render. | Cluster-independent and read-only. |
| `mise exec -- just kube qbittorrent-verify` | Checks live Flux and Helm readiness, Deployment rollout, HTTPRoute acceptance, DNS, and WebUI reachability. | Observer-tier, read-oriented scoped verification. |
| `mise exec -- just test probe qbittorrent` | Uses approved exec measurements and creates then removes one temporary no-VPN Pod to obtain an independent home-WAN reference. | Human-owned, state-changing measurement. It requires authority to create the temporary Pod. |
| Manual rotation-uptake checks | Compare the old and new Pod identities, deployed Secret revision, and a redacted key digest. | Operator-only manual acceptance because it includes ad-hoc exec and plaintext key input. |

The ordinary verifier and the stronger VPN probe answer different questions. Do not use
WebUI reachability as evidence that VPN egress is correct.

## Initial Proton credential setup

Proton's current manual port-forwarding instructions require a paid plan, a P2P-capable
server, and **NAT-PMP (port forwarding)** enabled when generating a WireGuard
configuration. Proton's account UI can change, so follow the current labels rather than
treating this navigation as a permanent API contract.

1. Sign in to the Proton VPN account and open **Downloads → WireGuard configuration**.
2. Generate a persistent WireGuard configuration for a P2P-capable server.
3. Enable **NAT-PMP (port forwarding)**. Keep **Moderate NAT** disabled because Proton
   does not support it together with port forwarding.
4. Copy only the `[Interface] PrivateKey`. Do not commit, retain in the repository, or
   mount the downloaded configuration file.
5. From the assigned feature worktree, load the repository's SOPS age identity and run:

   ```bash
   read -rs WIREGUARD_PRIVATE_KEY
   export WIREGUARD_PRIVATE_KEY
   export PROTONVPN_SECRETS_CONFIRM='write:media:protonvpn:sops'
   mise exec -- just repo protonvpn-secrets
   unset WIREGUARD_PRIVATE_KEY PROTONVPN_SECRETS_CONFIRM
   ```

6. Validate and stage both outputs:

   ```bash
   mise exec -- just kube qbittorrent-validate
   git add kubernetes/apps/media/qbittorrent/app/protonvpn.sops.yaml \
     kubernetes/apps/media/qbittorrent/app/values.yaml
   ```

The writer never passes the private key as a command-line argument or prints it. It uses
a mode-`0700` temporary directory under `/tmp`, creates files under `umask 077`, deletes
the temporary directory on exit, verifies the result is encrypted for the repository
recipient, and checks that neither the private key nor generated control-server API key
appears in the ciphertext.

The tracked outputs are:

- `kubernetes/apps/media/qbittorrent/app/protonvpn.sops.yaml`, containing the encrypted
  WireGuard private key and Gluetun `config.toml`;
- `kubernetes/apps/media/qbittorrent/app/values.yaml`, containing the non-secret
  `sops-hash` revision that must equal the encrypted Secret's Git blob hash.

Review, commit, and merge those files through the normal pull-request workflow. Flux
decrypts the Secret in the cluster. The Pod consumes both the private-key environment
variable and the `config.toml` `subPath` mount only at startup, so the changed annotation
makes the `Recreate` Deployment replace the complete qBittorrent/Gluetun Pod.

For a genuine empty-PVC deployment, keep the application suspended and use the guarded
bootstrap and blocking VPN-disconnect acceptance sequence documented in
[Media automation setup](media-automation-setup.md#greenfield-pvc-bootstrap). Do not infer
the greenfield procedure from the fact that the current deployment is active.

## Server selection

The repository declares:

```yaml
VPN_SERVICE_PROVIDER: protonvpn
VPN_TYPE: wireguard
WIREGUARD_PRIVATE_KEY: <from the SOPS Secret>
VPN_PORT_FORWARDING: "on"
PORT_FORWARD_ONLY: "on"
SERVER_COUNTRIES: Sweden
```

Gluetun's native Proton provider uses the account-scoped WireGuard private key and its
own server database. The Proton server selected while generating the configuration does
not pin Gluetun to that endpoint.

`SERVER_COUNTRIES: Sweden` states the actual requirement while allowing Gluetun to move
between valid Swedish P2P endpoints. `PORT_FORWARD_ONLY: on` restricts selection to
port-forwarding-capable servers. An exact `SERVER_HOSTNAMES` value would be brittle: if
that hostname disappears from Gluetun's server data, no alternative server can match.

The downloaded file fields are therefore used as follows:

| Generated WireGuard field | Use in this deployment |
| --- | --- |
| `PrivateKey` | Stored through SOPS and supplied to Gluetun. |
| `Address`, `DNS`, `PublicKey`, `Endpoint`, `AllowedIPs` | Not mounted; Gluetun derives its runtime configuration. |

## Dynamic port forwarding

The forwarded Proton port is temporary and may change whenever Gluetun reconnects:

```text
Gluetun connects to Proton
→ NAT-PMP obtains a forwarded port
→ the UP hook updates qBittorrent's listen_port and binds it to tun0
→ qBittorrent announces and listens on the Proton port
→ the DOWN hook resets listen_port to 0 and the interface to lo
```

The hooks call qBittorrent over `127.0.0.1:8080` inside the shared Pod. This depends on
qBittorrent's narrowly scoped localhost authentication bypass. Do not expand that bypass
to Pod, cluster, or RFC 1918 networks.

Never hard-code the forwarded port. Gluetun's up/down hooks and control-server state are
the runtime authorities for it.

## Normal verification

First validate the declarative contract:

```bash
mise exec -- just kube qbittorrent-validate
```

After the change is merged and Flux has reconciled it, run:

```bash
mise exec -- just kube qbittorrent-verify
```

### What `qbittorrent-verify` proves

- the qBittorrent Flux Kustomization and HelmRelease are Ready;
- the Deployment rollout completed;
- the HTTPRoute is accepted;
- internal DNS points the route to the expected Gateway address;
- the qBittorrent WebUI is reachable through that route.

### What it does not prove

- that a newly supplied Proton private key was loaded;
- that Gluetun's VPN status is `running`;
- that the exit country is Sweden;
- that qBittorrent uses the VPN address instead of the home WAN address;
- that the Proton forwarded port matches qBittorrent's listen port;
- that qBittorrent uses Gluetun's loopback DNS resolver.

The stronger operator-run measurement is:

```bash
mise exec -- just test probe qbittorrent
```

It uses exec inside the two containers, reads the Gluetun control API and qBittorrent
preferences, and creates one temporary `curlimages/curl` Pod outside the VPN path. That
Pod supplies an independent home-WAN reference and is removed before the command exits.
The probe then proves, without printing the measured addresses or ports, that:

- the VPN is running through Sweden;
- qBittorrent egress equals the VPN address and differs from the home WAN address;
- Gluetun's forwarded port equals qBittorrent's listen port;
- qBittorrent's resolver list contains only Gluetun loopback.

Because the probe creates live state and requires exec, it is not an observer-tier
verifier and must not be run with scoped read-only credentials.

## Renew or rotate the Proton credential

The Proton account currently displays an expiry for persistent WireGuard configurations
and provides an **Extend** action. This is operator-observed account behavior; Proton's
public setup documentation does not define the expiry or Extend UI as a stable contract.
Check the current dashboard rather than assuming the wording or interval will remain
unchanged.

### Extend the existing credential

When Proton extends the existing credential without changing its private key:

- no repository Secret changes;
- no rollout is needed;
- normal monitoring and verification continue.

### Replace the private key

When Proton issues a new key:

1. Keep the previous Proton configuration available and valid until acceptance passes.
2. Record the current qBittorrent Pod UID as described in the manual acceptance section.
3. Run `protonvpn-secrets` with the new key. The recipe rewrites the encrypted Secret,
   generates a new control-server API key, and stamps the new Secret revision.
4. Run `mise exec -- just kube qbittorrent-validate` and `mise exec -- just ci`.
5. Review, commit, and merge both tracked files through the normal pull-request path.
6. Wait for Flux and the `Recreate` Deployment to replace the Pod.
7. Prove credential uptake, then run the VPN behavior probe.
8. Retire the previous Proton credential only after every acceptance check passes.

Do not patch the live Secret or run an ad-hoc rollout restart. A Secret update without
the matching Pod-template revision can leave the old startup-loaded key active.

## Manual credential-uptake acceptance

No repository-owned command currently performs this complete rotation check. The
following manual sequence is therefore an operator-only acceptance procedure. It uses
ad-hoc `kubectl exec` and asks for the plaintext rotated key again. Keep shell tracing
disabled and do not print either digest.

Before merging the rotation, record the current Pod UID:

```bash
old_pod_uid="$(
  mise exec -- kubectl --kubeconfig .kube/config --namespace media get pods \
    --selector app.kubernetes.io/name=qbittorrent \
    --field-selector status.phase=Running \
    --output jsonpath='{.items[0].metadata.uid}'
)"
test -n "$old_pod_uid"
```

After Flux reconciles the merged commit:

```bash
mise exec -- just kube qbittorrent-verify

pod_name="$(
  mise exec -- kubectl --kubeconfig .kube/config --namespace media get pods \
    --selector app.kubernetes.io/name=qbittorrent \
    --field-selector status.phase=Running \
    --output jsonpath='{.items[0].metadata.name}'
)"
new_pod_uid="$(
  mise exec -- kubectl --kubeconfig .kube/config --namespace media get pod "$pod_name" \
    --output jsonpath='{.metadata.uid}'
)"
expected_revision="$(git hash-object kubernetes/apps/media/qbittorrent/app/protonvpn.sops.yaml)"
loaded_revision="$(
  mise exec -- kubectl --kubeconfig .kube/config --namespace media get pod "$pod_name" \
    --output jsonpath='{.metadata.annotations.sops-hash}'
)"
test "$new_pod_uid" != "$old_pod_uid"
test "$loaded_revision" = "$expected_revision"

set +x
read -rs WIREGUARD_PRIVATE_KEY
export WIREGUARD_PRIVATE_KEY
expected_key_digest="$(printf '%s' "$WIREGUARD_PRIVATE_KEY" | mise exec -- openssl dgst -sha256 | awk '{print $NF}')"
loaded_key_digest="$(
  mise exec -- kubectl --kubeconfig .kube/config --namespace media exec "$pod_name" \
    --container gluetun -- sh -c 'printf %s "$WIREGUARD_PRIVATE_KEY" | sha256sum' \
    | awk '{print $1}'
)"
test "$loaded_key_digest" = "$expected_key_digest"
unset WIREGUARD_PRIVATE_KEY expected_key_digest loaded_key_digest

mise exec -- just test probe qbittorrent
```

The UID check proves replacement, the annotation check binds the Pod to the tracked
encrypted Secret revision, and the digest comparison proves that the running Gluetun
process received the expected private key without exposing it.

## Failure and rollback

If reconciliation, Pod replacement, revision comparison, key comparison, or the VPN
probe fails, stop. Keep the fail-closed state in place.

Do not:

- bypass Gluetun or disable its firewall or encrypted DNS path;
- treat WebUI reachability as VPN acceptance;
- repeatedly restart the Pod hoping the problem clears;
- patch the Flux-managed Secret directly;
- use `kubectl rollout undo` against Flux-managed state;
- revoke the previous Proton credential before the replacement is accepted.

If the previous credential remains valid, revert the rotation commit through a reviewed
pull request. Flux then restores the previous encrypted Secret and Pod-template revision.
If neither key works, obtain a valid Proton port-forwarding credential and publish
another reviewed rotation. Do not create a non-VPN escape path.

For a sustained `running` state without a forwarded port, the deliberately slow
Kubernetes liveness probe restarts the Gluetun container after about five minutes. A
container restart keeps the Pod network namespace; whether that always clears the
partial failure has not been established. Repeated restarts trigger a critical alert.
Follow [Recover qBittorrent VPN egress](../runbooks/recovery.md#recover-qbittorrent-vpn-egress)
for the operator-managed recovery path.

## Monitoring

Reactive monitoring is implemented:

- Gatus polls the ClusterIP-only Gluetun status endpoint every minute and requires
  `status == running`.
- `QbittorrentVpnDown` becomes critical after that probe reports failure for more than
  five minutes.
- `QbittorrentVpnProbeMissing` warns when the probe metric is absent for more than
  fifteen minutes.
- `QbittorrentGluetunRestartLoop` becomes critical when the Gluetun container restarts
  at least twice within fifteen minutes and the condition persists for one minute.
- Alertmanager delivers these alerts through ntfy.

These signals detect failure after it occurs. The credential carries no locally usable
expiry timestamp, and this repository has no Proton expiry API or implemented expiry
metric. Use an external calendar or reminder before the date shown in the Proton account
as the proactive renewal control.

## Implementation reference

The current implementation is defined by:

- `kubernetes/apps/media/qbittorrent/app/values.yaml` — Gluetun and qBittorrent runtime
  configuration, hooks, probes, and rollout stamp;
- `kubernetes/apps/media/qbittorrent/app/protonvpn.sops.yaml` — encrypted private key and
  control-server authorization file;
- `.just/repository.just` — guarded Secret writer;
- `scripts/validate/qbittorrent.sh` — source and render contract;
- `scripts/verify/qbittorrent.sh` — observer-tier live verifier;
- `tests/probes/qbittorrent/probe.sh` — stronger VPN behavior measurement;
- `kubernetes/apps/monitoring/gatus/app/values.yaml` and
  `kubernetes/apps/media/alerts/app/qbittorrent.yaml` — reactive monitoring.

Upstream behavior is documented in Proton's
[manual port-forwarding guide](https://protonvpn.com/support/port-forwarding-manual-setup)
and [WireGuard configuration guide](https://protonvpn.com/support/wireguard-configurations),
and Gluetun's
[Proton provider](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md),
[WireGuard options](https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/wireguard.md),
[port-forwarding options](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md),
and [firewall behavior](https://github.com/qdm12/gluetun-wiki/blob/main/faq/firewall.md).
