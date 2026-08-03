# Spec Review

**Spec:** /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/2026-08-03-plex-public-envoy-amendment.md  
**Reviewer:** GPT-5.6-sol / Codex  
**Verdict:** Not ready — route admission and Cilium containment do not enforce their stated boundaries, and one hard gate cannot be completed deterministically.

## Findings

### F1 — Defect
**Where:** §6.2 control 3 and §6.3  
**Mechanism:** `allowedRoutes.namespaces.from: Selector` admits namespaces labelled `gateway.supermorphic.com/public-plex: "true"`, and that label is placed on the shared `media` namespace.  
**Failure:** Namespace selection cannot distinguish Plex’s HTTPRoute from the Sonarr, Radarr, qBittorrent, Prowlarr, Seerr, Lidarr, and Tautulli HTTPRoutes in the same namespace. All of them become eligible routes. A media route that references the public Gateway and omits `hostnames` or uses the Plex hostname can attach and route `plex.lab.supermorphic.com` to a non-Plex backend. The distinct label therefore does not provide the Plex-only admission claimed by control 3; only the separate exact-hostname control remains effective.  
**When:** Any current or future HTTPRoute in `media` references the public Gateway with no hostname or with `plex.lab.supermorphic.com`.

### F2 — Defect
**Where:** §7.2 Policy shape and §13 negative test 8  
**Mechanism:** Plex egress is allowed to `world:443`, described as restricting access to “the Plex cloud.”  
**Failure:** In Cilium, `world` is every endpoint outside the cluster and is equivalent to `0.0.0.0/0`; it is not a Plex-cloud selector. The rule permits TCP 443 to the NAS, UniFi, and arbitrary VLAN hosts outside Kubernetes, so negative test 8 cannot prove the stated containment when those targets listen on HTTPS. [Cilium’s Layer 3 policy documentation](https://docs.cilium.io/en/stable/security/policy/layer3/) confirms this entity behavior.  
**When:** An out-of-cluster VLAN endpoint accepts TCP 443.

### F3 — Defect
**Where:** §10, phase 4 gate  
**Mechanism:** Proceeding requires proof that “an address change propagates.” No operation that causes or simulates such a change is specified.  
**Failure:** A stable residential DHCP lease produces no address-change event, so the phase cannot satisfy its hard gate even when UniFi DDNS is configured and functioning correctly.  
**When:** Xfinity renews the existing WAN address or the address otherwise remains unchanged throughout the experiment.

### F4 — Contradiction
**Where:** §5.2 and §10  
**§5.2 says:** Issuing the dedicated certificate publishes the exact Plex hostname to Certificate Transparency logs.  
**§10 says:** Phases 0 through 4 are all reversible.  
**Why both cannot hold:** Certificate Transparency logs are public append-only ledgers; deleting the Certificate and public DNS record cannot retract the hostname disclosed during phase 3. [RFC 9162](https://www.ietf.org/rfc/rfc9162.html) defines that append-only property.

### F5 — Contradiction
**Where:** §10.1, §14.2, and §14.3  
**§14.2 says:** Phases 2a, 2b, and 2c are kept on failure.  
**§10.1 and §14.3 say:** Any internal-consumer regression triggers immediate revert, and an internal regression is handled by reverting that phase’s change.  
**Why both cannot hold:** If the watch-selector change or Cilium policy itself causes the regression—for example, phase 2b blocks native Sonos—one instruction retains the failing change while the other reverts it.

### F6 — Ambiguity
**Where:** §4.3, §6.2, and §10 phase 3  
**Reading 1:** The public Envoy copies the internal EnvoyProxy’s two replicas, `50m` CPU/`128Mi` memory requests, and PDB `minAvailable: 1`.  
**Reading 2:** The public Envoy specifies only its Service/VIP properties and inherits Envoy Gateway defaults for replicas and resources, with no explicit PDB.  
**Different implementations:** These produce different Deployments and PDBs, different availability during disruption, and different shared-node resource behavior. The spec requires a distinct Deployment and Service but never selects these values.

### F7 — Ambiguity
**Where:** §9 and §12  
**Reading 1:** “Access logging” means Envoy Gateway’s default JSON log to container stdout, retained only as Kubernetes runtime logs.  
**Reading 2:** It means configured telemetry with a persistent or centralized sink and an explicit format and retention period.  
**Different implementations:** Reading 1 adds no logging resources and loses evidence with pod/log rotation; reading 2 adds telemetry configuration, a sink, and retention infrastructure. The repository contains no Loki, Fluent Bit, Vector, Promtail, Alloy, or OpenTelemetry collector. Envoy Gateway documents stdout as the default sink and permits custom sinks and formats. [Envoy Gateway access-log documentation](https://gateway.envoyproxy.io/v1.8/tasks/observability/proxy-accesslog/)

### F8 — Ambiguity
**Where:** §9 DDNS drift check  
**Reading 1:** A CronJob periodically queries an IP-echo service and public DNS, then exposes failure through Kubernetes job metrics and the existing Alertmanager-to-ntfy route.  
**Reading 2:** A continuously running exporter polls both sources, publishes a drift gauge, and is monitored through a ServiceMonitor and PrometheusRule.  
**Different implementations:** These require different workload kinds, schedules, health behavior, resources, and validation. The IP-echo endpoint and public resolver are also unidentified, so implementations send observations to different external services.

### F9 — Scope
**Type:** Omitted  
**Where:** §15.3 New risks  
**Brief says:** “The risk assessment must reuse the same qualitative likelihood/impact scale as the 2026-08-02 register and show explicit deltas across three columns (Relay baseline, direct Plex exposure, dedicated external Envoy).”  
**Mismatch:** All 16 new-risk rows contain a single `L · I` rating. They do not show Relay, direct-Plex, and dedicated-Envoy ratings or explicit deltas across those options.

### F10 — Scope
**Type:** Omitted  
**Where:** §9 access logging and §15 risk register  
**Brief says:** “Security containment and a complete ranked failure/risk assessment are mandatory” and “all credible failure points are exposed and addressed.”  
**Mismatch:** The risk register does not assess authentication-token disclosure through public Envoy logs. Envoy Gateway’s default format records the original request path, including its query string, while Plex explicitly permits and documents `X-Plex-Token` as a URL parameter. A request using that authentication form places the token in the required access log. [Envoy Gateway default format](https://gateway.envoyproxy.io/v1.8/tasks/observability/proxy-accesslog/), [Plex token documentation](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)

## Grounding

- **Assumption:** The reviewed artifact is the requested revision.  
  **Checked:** SHA-256 of the full 635-line file.  
  **Found:** `7b5a94e06d83039b11d8b986bdaa502fcc3464ec39a7d426fd46ac2b500cfeaa`, matching the supplied first 16 characters.

- **Assumption:** The controller currently ignores a new public namespace.  
  **Checked:** `kubernetes/apps/networking/envoy-gateway/app/values.yaml` and namespace manifests.  
  **Found:** The controller uses the exact `access: internal` `matchLabels` selector. The proposed `networking-public` namespace does not exist, so widening is required.

- **Assumption:** Envoy Gateway creates distinguishable data planes in its controller namespace.  
  **Checked:** Envoy Gateway `v1.8.2` source, `scripts/verify/foundation.sh`, and the Gateway smoke test.  
  **Found:** The existing internal fleet is in `envoy-gateway-system` and is selected by `gateway.envoyproxy.io/owning-gateway-name: internal`. The repository already relies on that label. Upstream documents controller-namespace placement as the standard mode. [Envoy Gateway deployment modes](https://gateway.envoyproxy.io/docs/tasks/operations/gateway-namespace-mode/)

- **Assumption:** The public route-admission label isolates Plex from other media routes.  
  **Checked:** `kubernetes/apps/media/namespace/app/namespace.yaml` and all media HTTPRoutes.  
  **Found:** Plex and the other media applications share the single `media` namespace, confirming F1.

- **Assumption:** The Cilium policy can treat `world:443` as Plex-cloud-only access.  
  **Checked:** Cilium is pinned to `1.19.6`; its current configuration and matching upstream policy semantics were inspected.  
  **Found:** `world` means all endpoints outside the cluster, confirming F2.

- **Assumption:** Plex does not originate SMB traffic for its media mount.  
  **Checked:** `kubernetes/apps/media/storage/app/persistentvolume.yaml`, the Plex values, and storage validation scripts.  
  **Found:** Verified. The `media-data` PV uses `smb.csi.k8s.io`; the CSI node component performs the network mount, which is presented to Plex as a filesystem.

- **Assumption:** The current ExternalDNS deployment cannot modify Cloudflare.  
  **Checked:** `kubernetes/apps/networking/external-dns/app/values.yaml` and foundation validation.  
  **Found:** Verified for the current source: provider `pihole`, internal annotation filter, Gateway `internal`, domain filter, and `upsert-only`; no Cloudflare provider or credential is configured.

- **Assumption:** Plex’s declared pod hardening and the privileged namespace characterization are accurate.  
  **Checked:** Plex values and the `media` namespace manifest.  
  **Found:** Verified: UID/GID `568`, non-root execution, dropped capabilities, `RuntimeDefault`, no service-account token, and PSA `privileged`.

- **Assumption:** The existing wildcard certificate is ECDSA P-256.  
  **Checked:** `kubernetes/apps/security/cert-manager/certificate/certificate.yaml`.  
  **Found:** Verified. The proposed dedicated certificate’s algorithm, size, and rotation policy remain unspecified.

- **Assumption:** Public access logs have an existing persistent destination.  
  **Checked:** Kubernetes manifests for Loki, Fluent Bit/Fluentd, Vector, Promtail, Alloy, and OpenTelemetry collectors.  
  **Found:** None are present. Envoy Gateway’s default stdout logging is available, but persistence and retention are not established.

- **Assumption:** The diagrams follow the repository artifact pattern.  
  **Checked:** Both referenced SVG and PNG pairs and their dimensions.  
  **Found:** The files exist, Markdown embeds the PNGs and links the SVGs, and PNG dimensions match the SVG canvases. No repository recipe documenting deterministic SVG-to-PNG generation was found; that process is **UNVERIFIED**.

- **Assumption:** Removing the UniFi DNAT alone terminates all exposure in seconds, including established sessions.  
  **Checked:** Repository material and current authoritative UniFi port-forward/firewall documentation.  
  **Found:** **UNVERIFIED.** UniFi is stateful and distinguishes established connections, but its documentation does not establish that deleting a port-forward flushes existing connection state.

- **Assumption:** Plex’s TLS hostname is a hash derived from the server address and its certificate chain rotates on Plex’s schedule.  
  **Checked:** Current official Plex secure-connection documentation.  
  **Found:** **UNVERIFIED.** Official material confirms Plex-managed Let’s Encrypt certificates and `plex.direct`, but not the spec’s hash derivation or rotation characterization.

- **Assumption:** A sustained bitrate above 2 Mbps definitively proves a non-Relay path.  
  **Checked:** Plex’s documented Relay ceiling and the spec’s measurement procedure.  
  **Found:** The 2 Mbps Relay ceiling is documented, but the bitrate measurement source and sampling method are unspecified; the complete inference is **UNVERIFIED**.

- **Assumption:** Live cluster state matches Git.  
  **Checked:** Repository state only; no cluster-dependent recipe was run.  
  **Found:** **UNVERIFIED.** The available cluster credentials have unrecognized contexts, and live checks are operator-only under repository policy.