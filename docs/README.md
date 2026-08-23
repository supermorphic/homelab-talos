# Documentation

## Guides

- [Agent cluster access](guides/agent-cluster-access.md) — Install task-scoped read-only Kubernetes and Talos credentials in an agent worktree.
- [Media automation greenfield startup](guides/arr-stack-startup.md) — Configure qBittorrent, the Servarr applications, Lidarr, and Seerr on new persistent volumes.
- [GitHub main protection](guides/github-protection.md) — Inspect, verify, and recover the repository's protected-branch settings.
- [ntfy startup](guides/ntfy-startup.md) — Configure ntfy credentials, producers, consumers, rotation, and troubleshooting.
- [Prepare a clone and worktree](guides/operator-bootstrap.md) — Set up the pinned toolchain, linked worktrees, hooks, and scoped credentials.
- [Maintain the Pi-hole integration](guides/pihole-integration.md) — Reinstall, rotate, validate, and recover ExternalDNS access to Pi-hole.
- [Configure Plex direct remote access](guides/plex-direct-remote-access.md) — Operate the attended router path to Plex and validate or remove it safely.
- [Validate Plex remote-access detection](guides/plex-remote-access-validation.md) — Run the synthetic half-open connection exercise for the Plex alerting path.
- [Configure and recover Portainer](guides/portainer.md) — Manage Portainer setup, credentials, acceptance, and recovery within its read-only boundary.
- [ProtonVPN WireGuard and Gluetun](guides/protonvpn-gluetun.md) — Configure and operate qBittorrent's fail-closed VPN egress.
- [Configure qbit_manage deployment](guides/qbit-manage.md) — Create its credential and start or restore the scheduled policy workload.
- [SOPS secret handling](guides/sops.md) — Create, edit, validate, and recover encrypted repository secrets.
- [Tailscale access for the lab domain](guides/tailscale-lab-domain.md) — Configure and maintain private access to `*.lab.supermorphic.com`.
- [Configure the Tailscale Kubernetes Operator](guides/tailscale-operator.md) — Prepare tailnet settings and deploy or roll back the operator and ingress proxy group.
- [Tailscale single-user setup](guides/tailscale-single-user-setup.md) — Complete the first-time operator and private ntfy access walkthrough.
- [Test campaigns](guides/test-campaigns.md) — Plan, run, publish, and resume the standard, weekly, and full test campaigns.

## Reference

- [NUC Talos cluster](reference/nuc-cluster.md) — Look up the current synthetic hardware, network, and Talos image inputs.
- [qbit_manage CZTeam policy](reference/qbit-manage-czteam.md) — Look up the tracker-specific CZTeam classification and share-limit contract.
- [qbit_manage seeding policy](reference/qbit-manage.md) — Look up the active classification, seeding, cleanup, and safety contract.
- [Persistent test reports](reference/test-reports.md) — Look up report hosting, publication authority, retention, and recovery contracts.
- [Testing layers](reference/testing-layers.md) — Compare continuous, routine, controlled-failure, campaign, and conformance assurance layers.

## Runbooks

- [Recover Plex Relay or Sonos playback](runbooks/plex-relay-sonos.md) — Diagnose direct-path fallback and restore Plexamp or Sonos playback.
- [Respond to Plex remote-access alerts](runbooks/plex-remote-access-detection.md) — Diagnose, mitigate, and escalate direct-access alert conditions.
- [Recover the Talos and Flux platform](runbooks/recovery.md) — Recover repository, credential, node, network, GitOps, storage, and application failures.

## Specifications

- [001 — Lidarr Music Stack](specs/001-lidarr-music-stack.md) — Describes the implemented music automation design and its media-stack integration.
- [002 — Movie Encoding LA-ICQ Evaluation](specs/002-movie-encoding-la-icq-evaluation.md) — Records the completed LA-ICQ no-go evaluation, evidence, and reconsideration conditions.
- [003 — Tautulli Plex Analytics](specs/003-tautulli-plex-analytics.md) — Describes the implemented Tautulli analytics, persistence, routing, and integration design.
- [004 — Agent Runtime Policy](specs/004-agent-runtime-policy.md) — Explains the rationale for the repository's agent authority and safety boundaries.
- [005 — Flux Reconciliation Alerting](specs/005-flux-reconciliation-alerting.md) — Describes readiness alerts for Flux-managed resources and sources.
- [006 — Media Stack Architecture](specs/006-media-stack-architecture.md) — Describes the shared storage, networking, security, and dependency model for media applications.
- [007 — ntfy Notification Architecture](specs/007-ntfy-notification-architecture.md) — Describes the private notification service and authenticated producer and consumer paths.
- [008 — Plex Relay and Sonos Integration](specs/008-plex-relay-sonos.md) — Records the retained Relay fallback, Sonos boundary, and Plex workload controls.
- [010 — Portainer GitOps Observability](specs/010-portainer-gitops-observability.md) — Describes Portainer's read-only observability design within GitOps authority boundaries.
- [011 — Talos and Flux Platform](specs/011-talos-flux-platform.md) — Describes the implemented three-node Talos, Flux, networking, and storage architecture.
- [013 — Test Reporting Standard](specs/013-test-reporting-standard.md) — Defines the implemented assurance, evidence, catalog, campaign, and reporting design.
- [017 — Plex Public Envoy Experiment](specs/017-plex-public-envoy-experiment.md) — Records the retired public Envoy design, failed Sonos result, and reconsideration conditions.
- [019 — Plex Direct Remote Access](specs/019-plex-direct-remote-access.md) — Describes the current Plex router exposure, identity, containment, and rollback design.
- [020 — Plex Remote-Access Detection](specs/020-plex-remote-access-detection.md) — Describes Hubble-based aggregate detection for sustained off-cluster Plex traffic.
- [021 — Alerting Architecture](specs/021-alerting-architecture.md) — Describes rule ownership, validation coverage, routing, and focused workload-policy alerts.
- [026 — Cert-manager Staging Retirement](specs/026-cert-manager-staging-retirement.md) — Records why permanent staging resources were removed and the production certificate boundary.
- [027 — FileFlows QSV HEVC ICQ Evaluation](specs/027-fileflows-qsv-hevc-icq-evaluation.md) — Describes the ICQ benchmark design, diagnostics, quality gates, and evidence contract.
- [028 — Media Integration Health Collector](specs/028-media-integration-health-collector.md) — Records the first unimplemented collector design and its retained assurance model.
- [029 — Media Integration Health Active Probes](specs/029-media-integration-health-active-probes.md) — Records the unimplemented active-probe revision and why it was replaced.
- [030 — Media Integration Health with Gatus](specs/030-media-integration-health-gatus.md) — Records the implemented Gatus redesign before its API-success semantics changed.
- [031 — Media Integration Health API Reachability](specs/031-media-integration-health-api-reachability.md) — Describes the current authenticated Servarr reachability checks and alerts.
- [022 — Documentation Lifecycle Migration](specs/022-documentation-lifecycle-migration.md) — Describes the migration from legacy lifecycle records to the current documentation structure.
