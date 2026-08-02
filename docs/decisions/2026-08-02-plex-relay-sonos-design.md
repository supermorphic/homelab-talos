# Plex Relay and Sonos integration — design

Status: Accepted (2026-08-02)
Implementation is sequenced in the
[Plex Relay and Sonos implementation plan](../plans/2026-08-02-plex-relay-sonos-implementation-plan.md).
Date: 2026-08-02.
Branch: `investigate-plex-remote-access`.

## 1. Decision

Use **Plex Relay** as the primary off-site path for Plex and the Plex service for
Sonos. Do not publish Plex through a UniFi WAN port forward, Tailscale Funnel,
Cloudflare Tunnel, or a VPS unless Relay proves insufficient after production
acceptance.

The live experiment established that Relay works end to end when the Plex process,
which runs as numeric UID/GID `568`, has a matching passwd identity. The permanent
functional change is therefore narrow: generate a passwd file in an unprivileged
init container, add the missing Plex identity, and mount that file read-only at
`/etc/passwd` in the Plex container. Plex's native Relay key cache must remain
untouched.

This design also hardens the Plex workload because avoiding an inbound port does not
make Plex, its account, its config volume, or its network access risk-free.

## 2. Goals and acceptance criteria

The complete outcome has three distinct acceptance gates:

1. **Remote library:** with Wi-Fi and Tailscale disabled, Plexamp on the iPhone can
   browse and play the Plex Music library over cellular through Relay.
2. **Plex inside Sonos:** the already-authorized Plex music service in the native
   Sonos app can select the intended Music library, browse it, and play a track.
3. **Sonos inside Plexamp:** after the Plex and Sonos accounts are linked from a
   supported Plex app on the Sonos players' local network, the Sonos players appear
   in Plexamp's Players menu and accept playback without AirPlay.

Gate 1 proves the server's cloud reachability. Gate 2 proves the Sonos cloud service
can reach and use the library. Gate 3 is a separate Sonos account-linking and local
discovery/control path; Relay success alone does not prove it.

### Non-goals

- Exposing high-bitrate video remotely. Plex Relay limits streams to 2 Mbps and may
  transcode content above that rate.
- Making Plex highly available. It remains one active Deployment over a single-writer
  config PVC.
- Broadly joining the Main, IoT, and cluster VLANs.
- Replacing Sonos's native network requirements with a generic multicast reflector.
- Disabling Plex authentication for any CIDR.

## 3. Confirmed environment

| Component | Confirmed state |
|---|---|
| iPhone / Plexamp | Main VLAN, `192.168.10.0/24` |
| Sonos Ports | Wired IoT VLAN, `192.168.20.0/24` |
| Kubernetes nodes and gateway | Cluster VLAN, `192.168.90.0/24` |
| Plex service | `ClusterIP`, TCP `32400`, behind the internal Envoy Gateway |
| Local Plex URL | `https://plex.lab.supermorphic.com` |
| Plex container | `ghcr.io/home-operations/plex:1.43.3.10828`, tested index digest `sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7`, UID/GID `568` |
| Plex config | Longhorn `ReadWriteOncePod` PVC, writable at `/config` |
| Media | Shared SMB PVC mounted at `/Volumes/Prometheus`, currently writable |
| UniFi policy | Sonos-to-Main control is allowed and native Sonos playback works |
| Plex settings | Remote Access enabled but not publicly reachable; Relay enabled; no unauthenticated CIDRs |
| Sonos authorization | Plex music service successfully linked in Sonos, but its library was inaccessible before Relay worked |

The Plex `LAN Networks` setting and **Treat WAN IP as LAN Bandwidth** affect Plex's
bandwidth classification. They are not firewall rules, authentication bypasses, or
cross-VLAN discovery mechanisms. The unauthenticated-network list remains empty.

## 4. Root cause and experimental evidence

### 4.1 Failure

The support bundle showed Plex receiving cloud `startRelay` events and launching its
bundled `Plex Relay` child. The child exited with status `255` within milliseconds.
The live container then reproduced the decisive error:

```text
No user exists for uid 568
```

The image defines `nobody` as its default identity, but the pod overrides the process
to UID/GID `568`; the image's `/etc/passwd` has no entry for that UID. The Relay
binary requires a resolvable local user identity, while the main Plex process does
not.

A preliminary experiment also mounted Plex's published raw Relay public key over the
cached `relayHostKey.txt`. That was invalid: the cache is a transformed known-hosts
file, not the raw published key. Plex rejected the format and could not replace the
read-only mount. The raw key is not part of this design.

### 4.2 Minimal successful experiment

The corrected experiment changed one variable: it generated `/etc/passwd` with this
additional identity and mounted it read-only into the app container:

```text
plex:x:568:568:Plex Media Server:/config:/usr/sbin/nologin
```

The existing non-root UID, dropped capabilities, and
`allowPrivilegeEscalation: false` remained in force. The native Relay cache remained
writable under `/config` and unmodified by the experiment.

Sanitized evidence from the corrected run was:

```text
relay_current_uid_has_passwd_entry=yes
relay_key_cache_readable=yes
relay_tcp_443_reachable=yes
Relay: starting relay
[PlexRelay] Authenticated to <relay-host>:443
[PlexRelay] Allocated port <ephemeral> for remote forward to 127.0.0.1:32401
```

With Wi-Fi and Tailscale disabled, the operator then browsed and played music in
Plexamp over cellular. The bounded experiment rolled the Deployment back, resumed
and reconciled the Plex HelmRelease and Flux Kustomization, and passed the guarded
live Plex verification afterward. The current production manifest therefore still
lacks the repair until this design is implemented.

## 5. Architecture and data flow

### 5.1 Selected Relay path

```text
Plexamp or Sonos service
        │ outbound secure connection
        ▼
Plex-operated cloud / Relay
        ▲
        │ outbound TCP 443, initiated by Plex Media Server
        │ encrypted Plex connection; no UniFi WAN DNAT
        ▼
Plex pod :32401 loopback → Plex Media Server
```

Plex documents Relay as two secure connections meeting at a Plex Relay server. With
secure connections enabled, Plex states that content remains end-to-end encrypted
and the Relay does not terminate the server certificate. Relay is enabled by default,
supports limited remote access when direct Remote Access fails, and caps streams at
2 Mbps. Downloads cannot run over Relay. See
[Accessing a Server through Relay](https://support.plex.tv/articles/216766168-accessing-a-server-through-relay/).

The Plex server initiates outbound Relay connectivity. UniFi receives no new inbound
WAN rule, Plex receives no dedicated MetalLB public-service VIP, and no Internet
client can directly select a cluster address.

### 5.2 Plex service in the Sonos app

The Plex service for Sonos is cloud-mediated and must be able to reach Plex Media
Server. Plex explicitly says that normal Remote Access gives the best experience but
that Relay can provide the limited connection when Remote Access is not directly
reachable, provided Remote Access is not disabled. See
[Requirements for using Plex for Sonos](https://support.plex.tv/articles/218237558-requirements-for-using-plex-for-sonos/).

Once the permanent Relay repair is active, the native Sonos app should use the
existing Plex authorization to list accessible libraries. If Plex selected the wrong
library, the operator chooses the Music library under **Other Libraries**. See
[Navigating Plex for Sonos](https://support.plex.tv/articles/218168838-navigating-plex-for-sonos/).

### 5.3 Sonos players in Plexamp

Plex-to-Sonos control is not enabled merely by making Plex Media Server remotely
reachable. It requires:

- an active Plex Pass;
- a full Plex account rather than a managed user;
- initial linking from a supported Plex app while that device is on the same local
  network/Wi-Fi as the Sonos device; and
- authorization of the Sonos account to the Plex account.

These are Plex's documented requirements in
[Control Sonos Playback With a Plex App](https://support.plex.tv/articles/control-sonos-playback-with-a-plex-app/).
Plexamp is a supported Plex Companion controller and Sonos is a receiver; Sonos
control requires Plex Pass. See
[Supported Plex Companion Apps](https://support.plex.tv/articles/203082707-supported-plex-companion-apps/).

Because the iPhone and Sonos Ports are on different VLANs, a routed allow rule does
not necessarily satisfy the initial same-local-network discovery step. The first
test after Relay is permanent is therefore to place the iPhone temporarily on an
SSID mapped to the IoT VLAN, open the Players menu, select the Sonos linking entry,
and complete Sonos OAuth. If no such SSID exists, create a temporary VLAN-20 test
SSID for this acceptance step and remove it afterward; do not widen inter-VLAN
firewall policy as a substitute. After linking, return the iPhone to the Main VLAN
and test normal use. Sonos itself documents same-subnet operation as its supported
network topology in
[Sonos system requirements](https://support.sonos.com/en-gb/article/sonos-system-requirements).

Do not add broad multicast reflection or an any-to-any inter-VLAN rule merely because
the Players menu is empty. If same-VLAN linking succeeds but Main-VLAN control still
fails, capture the precise flows first and permit only the required protocol,
direction, player group, and destination ports.

## 6. Permanent workload design

### 6.1 Runtime identity repair

Keep Plex at numeric UID/GID `568`. Add one init container based on the same pinned
Plex image. It runs under the pod's non-root identity and:

1. copies the image's `/etc/passwd` into a dedicated `emptyDir`;
2. appends the `plex` entry shown in §4.2 only when UID `568` is not already
   defined;
3. verifies as a postcondition that UID `568` resolves to a passwd entry;
4. sets the generated file to mode `0644`; and
5. exits before the app starts.

Mount only the generated file into the Plex container at `/etc/passwd` using a
read-only `subPath`. Do not replace `/etc/group`, mutate the image filesystem, run a
privileged init container, change config-PVC ownership, or add Linux capabilities.

The design intentionally keeps UID/GID `568`: the existing config and SMB ownership,
Longhorn recovery behavior, and Intel GPU device access have already been validated
with it. Changing the whole workload to the image's `nobody` identity would create a
larger storage and GPU migration with no security benefit.

### 6.2 Pod and filesystem hardening

The permanent manifest must preserve or add:

- `runAsNonRoot: true`, `runAsUser: 568`, and `runAsGroup: 568`;
- `seccompProfile.type: RuntimeDefault` at pod level;
- `allowPrivilegeEscalation: false` and `capabilities.drop: [ALL]` for every
  container;
- `automountServiceAccountToken: false` because Plex does not use the Kubernetes API;
- an immutable image reference for the tested Plex version and digest;
- `/config` as the only persistent writable Plex data surface;
- `/transcode` as disposable `emptyDir`; and
- the shared media mount read-only.

Making media read-only removes Plex's ability to delete, rename, optimize into, or
otherwise modify the library. Lidarr/Sonarr/Radarr remain the file-management
authorities. This materially reduces ransomware and accidental-deletion impact if
Plex is compromised.

`readOnlyRootFilesystem` is not required in the first implementation because the
image's complete runtime write set has not been proven. It may be added later only
after writable paths are inventoried and supplied as bounded ephemeral mounts.

### 6.3 Network containment

A Plex-specific `CiliumNetworkPolicy` is required before this work is considered
fully hardened. It will default-deny selected Plex traffic and permit only exact,
documented paths established by live observation or an accepted source contract:

**Ingress to TCP 32400**

- internal Envoy Gateway;
- Homepage's Plex widget;
- the named media applications that use Plex's runtime connector, including Seerr,
  Sonarr, Radarr, Lidarr, and Tautulli; and
- `host`/`remote-node` for kubelet probes.

**Egress**

- cluster DNS on TCP/UDP 53;
- Internet TCP 443 for Plex account, metadata, update checks, pubsub, and Relay; and
- any additional flow demonstrated as necessary by Hubble during library scanning,
  remote playback, and Sonos acceptance.

The pragmatic `world:443` allowance still permits HTTPS command-and-control or data
exfiltration after a Plex compromise. Its benefit is containment of arbitrary
cluster/LAN scanning and non-HTTPS egress without relying on a brittle list of Plex
CDN and Relay addresses. Do not add general `cluster`, `remote-node`, Main-VLAN, or
IoT-VLAN egress without captured evidence.

Apply and test the policy separately from the identity repair so a failure has one
clear cause. Hubble observation precedes enforcement; policy verification includes
both required positive paths and denied negative paths.

Tautulli's accepted design declares the exact in-cluster dependency
`http://plex.media.svc.cluster.local:32400`. Its endpoint selector is therefore a
source-declared least-privilege allowance even while the newly staged Tautulli
Kustomization remains suspended. Task 7 records whether the flow has also been observed
after Tautulli activation; absence of that observation must not cause the exact declared
consumer to be omitted and broken by Plex policy enforcement.

## 7. Public-port trust-boundary baseline

The selected Relay design avoids the inbound path below. The diagram is retained
because it defines the fallback's exact exposure and prevents a future “one port is
harmless” assumption.

![Plex public-port trust boundaries](images/2026-08-02-plex-remote-access-trust-boundaries.png)

Editable source:
[2026-08-02-plex-remote-access-trust-boundaries.svg](images/2026-08-02-plex-remote-access-trust-boundaries.svg).

A single DNAT does **not** automatically expose every VLAN or the Kubernetes API.
It exposes Plex continuously, and a Plex compromise inherits the pod's mounts,
credentials, devices, and permitted routes. A container/kernel/runtime/GPU escape is
lower probability but potentially node- and cluster-impacting. Those distinctions
drive the mitigations in §6 and the risk register in §9.

## 8. Alternatives and recommendation order

| Rank | Option | Inbound home port | Compatibility and benefit | Principal cost/risk | Decision |
|---:|---|---|---|---|---|
| 1 | Plex Relay | No | Plex-native; empirically works with Plexamp; explicitly supported as a limited Sonos fallback | 2 Mbps cap, no downloads, Plex-cloud dependency, some apps unsupported | **Selected** |
| 2 | Direct TCP 32400 | Yes, one | Best performance and Plex's preferred Sonos experience | Continuously public Plex parser/API; depends heavily on workload containment and patch speed | Hardened fallback only |
| 3 | Tailscale Funnel | No router DNAT, but public | Encrypted public tunnel that hides the home IP | Funnel is beta, uses only tailnet DNS names and selected ports, and has non-configurable bandwidth limits | Contingency |
| 4 | Cloudflare Tunnel | No router DNAT, but public | Outbound-only `cloudflared` connector; hides origin IP | Standard public HTTP path terminates at Cloudflare; Access requires headers/cookies Plex/Sonos clients cannot be configured to send; media-delivery policy concerns | Not recommended for Plex media |
| 5 | VPS reverse tunnel | No home DNAT; VPS is public | Full operator control and stable public IP | Adds a public host, patching, credentials, bandwidth cost, and another compromise pivot | Last resort |

### 8.1 Why private Tailscale is not in the ranking

The existing private tailnet is useful for the operator's own Plex clients, but it
does not solve the Plex service for Sonos: Plex's/Sonos's cloud service is not a
tailnet member and cannot present tailnet credentials. Tailscale **Funnel**, not
private Serve/ingress, is the relevant public alternative. Tailscale documents that
Funnel uses an encrypted relay-backed TCP proxy, is public, is currently beta, only
supports `443`, `8443`, and `10000`, and has non-configurable bandwidth limits. See
[Tailscale Funnel](https://tailscale.com/kb/1223/funnel).

### 8.2 Cloudflare Tunnel assessment

Cloudflare Tunnel uses an outbound-only `cloudflared` connector, so it avoids router
DNAT and hides the origin IP. See
[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/).
That improves origin concealment but does not make Plex private: a published HTTP
hostname is still an Internet-reachable Plex endpoint.

Cloudflare Access service authentication requires client headers and then a JWT
cookie or token. Plexamp, Plex's Sonos integration, and Sonos players provide no
supported way to inject those Cloudflare credentials, so Access cannot be placed in
front of this flow. This compatibility conclusion is an inference from Cloudflare's
[service-token protocol](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/)
and the fixed Plex/Sonos client flows.

Cloudflare also documents restrictions around delivering video through its general
network. Even though the immediate workload is music, Plex is a mixed-media server;
the operator would need a current plan-and-policy review before proxying it. See
[Delivering Videos with Cloudflare](https://developers.cloudflare.com/fundamentals/reference/policies-compliances/delivering-videos-with-cloudflare/).

### 8.3 Direct-port fallback requirements

If Relay's bandwidth, availability, or client support becomes unacceptable, the only
approved direct design is:

- one dedicated MetalLB VIP for the Plex Service;
- one manually configured UniFi TCP DNAT to internal port `32400`;
- UPnP and NAT-PMP disabled for Plex/router auto-configuration;
- no public Envoy wildcard route and no other forwarded ports;
- Plex's manually specified public port matching the UniFi rule;
- all §6 hardening complete first;
- external negative scans proving every non-Plex port closed; and
- documented rollback that removes the DNAT and public Service address.

Plex documents manual external-port-to-internal-`32400` forwarding in
[Troubleshooting Remote Access](https://support.plex.tv/articles/200931138-troubleshooting-remote-access/).

## 9. Security risk register

Ratings are qualitative for this homelab: likelihood assumes Relay, current Plex
account authorization, and the §6 controls; impact assumes the control itself fails.

| Threat | Likelihood | Impact | Required controls | Residual risk |
|---|---|---|---|---|
| Unauthenticated Internet probing/exploitation | Low with Relay | High | No WAN DNAT; no public Service; secure Plex connections; patch promptly | Plex cloud/Relay and authorized clients still deliver traffic to Plex; Relay is reduced exposure, not an application sandbox |
| Plex account or token compromise | Medium | High | Unique password, MFA, review authorized devices, revoke tokens/sessions after suspicion, keep unauthenticated CIDRs empty | A valid account/token can access granted libraries and may change server state according to Plex authorization |
| Plex process compromise | Low–medium | High | Non-root, dropped capabilities, no privilege escalation, RuntimeDefault seccomp, immutable image, no service-account token | Attacker controls the writable config PVC and process memory, including Plex credentials |
| Media destruction or ransomware | Low after change | High | Mount media read-only; retain NAS/Longhorn backups; file managers remain the `*arr` apps | An attacker can still read/exfiltrate media and damage Plex metadata/config |
| Lateral movement to cluster or VLANs | Medium before policy; low after | High | Plex-specific Cilium policy; `world:443` only; no broad LAN egress; verify denied flows | HTTPS exfiltration remains possible; policy or Cilium defects can weaken isolation |
| Kubernetes API abuse | Low | High | `automountServiceAccountToken: false`; no RBAC role/binding | Node escape or unrelated credential theft bypasses this control |
| Container, kernel, runtime, or GPU escape | Low | Severe | Talos/runtime/GPU updates, non-root, seccomp, no capabilities, no privilege escalation, minimal devices | Hardware transcoding exposes the GPU driver; isolation reduces but cannot eliminate escape risk |
| Supply-chain compromise | Low–medium | High | Pin tested image digest; review update diffs; CI render validation; prompt security updates | A signed or pinned malicious artifact remains malicious; digest pinning provides immutability, not provenance proof |
| Relay/Plex-cloud outage or policy change | Medium | Medium | Local access remains independent; document direct-port fallback; monitor Relay lifecycle | Sonos cloud browsing and off-site use fail until Plex recovers or fallback is activated |
| Relay bandwidth exhaustion / transcoding load | Medium | Low–medium | 2 Mbps expectation; audio-first use; transcode limits and resource monitoring | High-bitrate audio may transcode; Relay is unsuitable for unrestricted remote video |
| Third-party privacy exposure | Medium | Medium | Secure connections; minimum account sharing; understand Plex metadata/account processing | Plex observes connection metadata and operates the relay even when content stays encrypted |
| Configuration regression | Medium | Medium | Static assertions for UID identity, security contexts, mounts, image digest, and policy; guarded live verification | Plex/image updates can change passwd contents or Relay behavior and require reassessment |

### Cluster and VLAN escape assessment

An inbound Plex port would not itself route an attacker to every VLAN. The realistic
chain is: exploit Plex, gain code execution in the pod, then use the pod's filesystem,
network routes, credentials, device access, or a second escape vulnerability. Without
a Plex NetworkPolicy, the lateral-network step is materially easier. With §6 controls,
the likely application-compromise impact is bounded to Plex memory/config and
read-only media plus HTTPS egress; broader node/VLAN harm requires an additional
policy failure, exposed credential, or container/kernel/GPU escape.

Relay removes opportunistic direct scanning of the home address, but the same pod
hardening remains necessary because Plex still processes remote authenticated
requests and Internet-fetched metadata.

## 10. Plex configuration requirements

Keep or set:

- **Remote Access:** enabled; no manually specified public port while Relay is the
  selected design.
- **Enable Relay:** enabled.
- **Secure connections:** `Required` if every used Plex/Sonos client passes
  acceptance; otherwise `Preferred`, which Plex also supports for Relay.
- **Strict TLS configuration:** enable only after Plexamp and Sonos acceptance proves
  client compatibility.
- **Custom server access URLs:** retain `https://plex.lab.supermorphic.com` for LAN
  discovery; it did not prevent the successful Relay experiment.
- **LAN Networks:** list only actual trusted local CIDRs for bandwidth treatment.
- **Allowed without auth:** empty.
- **GDM/local discovery:** retain for local Plex discovery; do not assume it crosses
  VLANs.
- **Remote streams per user:** `2`, rather than `Unlimited`.
- **Upload speed / remote bitrate:** record real WAN upload capacity; Relay's own
  2 Mbps ceiling still applies.

Plex requires secure connections to be `Preferred` or `Required` for Relay and
describes the resulting encrypted path in its Relay documentation cited in §5.1.

## 11. Failure handling and rollback

### Identity repair failure

If the init container cannot generate a valid passwd file, the app container must not
start. Kubernetes leaves the previous `Recreate` deployment unavailable rather than
running a partially repaired pod. The rollout is rolled back through the repository's
guarded workflow or a Git revert; never patch the live Deployment as the permanent
fix.

### Relay failure

Local Plex through the internal gateway remains available. Sanitized logs distinguish:

- no `startRelay` event: account/cloud/discovery issue;
- child exit before authentication: local Relay process/identity/key issue;
- authenticated but no allocated port: Plex Relay service/path issue; and
- allocated port but client failure: account, client discovery, authorization, or
  library selection issue.

Logs and diagnostics must redact Plex tokens, account identifiers, email addresses,
and unrelated request paths.

### Network-policy failure

Remove or revert only the Plex policy, verify the Deployment and local `/identity`,
then return to Hubble observation. Do not widen the policy to all namespaces or LANs
as an emergency shortcut.

## 12. Validation and rollout acceptance

### Static and render validation

- Add a regression test that fails when UID `568` lacks the generated passwd mount.
- Assert the init container is non-root, uses no extra capability, writes only the
  dedicated `emptyDir`, and mounts no Relay key.
- Assert the app's `/etc/passwd` mount is `readOnly` with the expected `subPath`.
- Assert `runAsNonRoot`, RuntimeDefault seccomp, dropped capabilities, no privilege
  escalation, and disabled service-account-token automount.
- Assert the media mount is read-only and `/config` remains writable.
- Assert the tested image digest.
- Validate and render the Cilium policy plus its exact selector and ports.
- Run `mise exec -- just ci` before handoff.

### Guarded live acceptance

1. Verify Flux Kustomization and HelmRelease readiness, Deployment rollout, internal
   HTTPRoute, DNS, and `/identity` using the existing guarded Plex verification.
2. Verify inside the Plex app container that UID `568` resolves to the expected
   non-login `plex` identity without printing environment variables or config files.
3. Trigger a remote Plexamp attempt and observe sanitized Relay lifecycle logs for
   authentication and remote-port allocation.
4. Disable iPhone Wi-Fi and Tailscale; browse and play a Music track in Plexamp.
5. In the Sonos app, open Plex, choose the intended Music library, browse, and play a
   track on a Sonos Port.
6. For initial Plex-to-Sonos linking, put the iPhone on the Sonos IoT network, open a
   supported Plex app's Players menu, select the Sonos link entry, and complete Sonos
   authorization. Return the iPhone to Main Wi-Fi.
7. In Plexamp on Main Wi-Fi, verify every intended Sonos player appears and play a
   track to one without AirPlay.
8. Confirm no public TCP `32400` DNAT or public Kubernetes Service exists.
9. Observe normal Plex, scan, Relay, Sonos, and metadata flows in Hubble; then enforce
   and verify the Plex Cilium policy.
10. Prove allowed internal/HTTPS paths still work and representative unapproved
    cluster, Main-VLAN, and IoT-VLAN destinations are denied.

## 13. Implementation boundaries

The implementation plan should keep failures attributable by separating these
changes into reviewable tasks:

1. source validation for the runtime-identity invariant;
2. init-generated passwd mount and pod hardening;
3. read-only media plus image immutability;
4. Relay/Plexamp and native Sonos-service acceptance;
5. same-VLAN Sonos account linking and Plexamp player acceptance; and
6. observed-then-enforced Cilium network containment.

No task may introduce a direct WAN port, public Service, Cloudflare Tunnel, Funnel,
or unauthenticated Plex CIDR. Activating any fallback is a new operator-approved
decision against §8, not an incidental troubleshooting step.

## 14. Decision record

| Decision | Outcome |
|---|---|
| Preferred remote path | Plex Relay |
| Public inbound home port | None |
| Plex runtime UID/GID | Keep `568:568` |
| Relay identity fix | Init-generated read-only `/etc/passwd` |
| Relay host key | Plex-owned native cache; never replaced by Git or a mount |
| Media permissions | Read-only to Plex |
| Pod API credential | No service-account token automount |
| Lateral containment | Plex-specific Cilium policy after observed flow inventory |
| Tailscale private ingress | Useful for operator clients, insufficient for Sonos cloud |
| First fallback | Hardened direct TCP `32400` only with explicit approval |
| Sonos player discovery | Same-local-network account-linking test before any VLAN expansion |
