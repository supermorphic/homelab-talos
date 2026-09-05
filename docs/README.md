# Documentation

## Guides

- [Agent cluster access](guides/agent-cluster-access.md) — Install task-scoped read-only Kubernetes and Talos credentials in an agent worktree.
- [Automation-data PostgreSQL operations](guides/automation-data-operations.md) — Activate and operate dynamic n8n domain provisioning, rotation, backups, and full-chain acceptance.
- [Media automation greenfield startup](guides/media-automation-setup.md) — Configure qBittorrent, the Servarr applications, Lidarr, and Seerr on new persistent volumes.
- [n8n operations](guides/n8n-operations.md) — Create the encrypted recovery unit, activate the private platform and exact public webhook, verify it, and roll it back safely.
- [GitHub main protection](guides/github-main-protection.md) — Inspect, verify, and recover the repository's protected-branch settings.
- [ntfy operations](guides/ntfy-operations.md) — Configure ntfy credentials, producers, consumers, rotation, and troubleshooting.
- [Repository and worktree setup](guides/repository-worktree-setup.md) — Prepare the operator-controlled primary checkout and isolated task worktrees.
- [Maintain the Pi-hole integration](guides/pihole-externaldns-operations.md) — Reinstall, rotate, validate, and recover ExternalDNS access to Pi-hole.
- [Plex remote-access operations](guides/plex-remote-access-operations.md) — Establish, validate, change, or remove the production Plex Internet path.
- [Plex remote-access detection test](guides/plex-remote-access-detection-test.md) — Deliberately generate bounded half-open traffic to prove the security-alert pipeline.
- [Operate and recover Portainer](guides/portainer-operations.md) — Inspect Portainer, manage its credentials, verify the read-only boundary, and recover retained state.
- [qBittorrent VPN operations](guides/qbittorrent-vpn-operations.md) — Configure and operate qBittorrent's fail-closed Proton VPN egress.
- [qbit_manage operations](guides/qbit-manage-operations.md) — Operate the active policy, rotate credentials, bootstrap safely, and recover mistakes.
- [SOPS secret operations](guides/sops-secret-operations.md) — Create, validate, and recover encrypted repository secrets.
- [Tailscale initial setup](guides/tailscale-initial-setup.md) — Establish the tailnet, clients, Operator foundation, and first private service in the correct order.
- [Tailscale Operator operations](guides/tailscale-operator-operations.md) — Deploy, verify, rotate, and recover the Kubernetes Operator and shared ingress proxy group.
- [Tailscale lab-domain access](guides/tailscale-lab-domain-access.md) — Configure and maintain private access to `*.lab.supermorphic.com`.
- [Test campaign operations](guides/test-campaign-operations.md) — Choose, plan, run, publish, and resume test campaigns.

## Reference

- [Repository command lifecycle](reference/repository-command-lifecycle.md) — Classify command semantics, workflow profiles, safeguards, confirmation, and execution authority.
- [NUC Talos cluster](reference/nuc-cluster.md) — Look up the current synthetic hardware, network, and Talos image inputs.
- [qbit_manage CZTeam policy](reference/qbit-manage-czteam.md) — Look up the tracker-specific CZTeam classification and share-limit contract.
- [qbit_manage seeding policy](reference/qbit-manage.md) — Look up the active classification, seeding, cleanup, and safety contract.
- [Persistent test reports](reference/test-reports.md) — Look up report hosting, publication authority, retention, and recovery contracts.
- [Testing layers](reference/testing-layers.md) — Compare continuous, routine, controlled-failure, campaign, and conformance assurance layers.

## Runbooks

- [Recover n8n](runbooks/n8n-recovery.md) — Choose pod, Longhorn, logical-restore, or full-reconstruction recovery while preserving the matching encrypted key.
- [Recover automation-data PostgreSQL](runbooks/automation-data-recovery.md) — Recover the shared domain database platform and prove the restored n8n credential-to-role-verifier chain.
- [Recover Plex remote playback with Relay](runbooks/plex-relay-fallback.md) — Diagnose Relay fallback when direct remote access is unavailable.
- [Recover Plex and Plexamp Sonos playback](runbooks/plex-sonos-recovery.md) — Restore native Sonos library access or Plexamp player control.
- [Respond to Plex network alerts](runbooks/plex-network-alerts.md) — Diagnose, contain, and recover Plex traffic, telemetry, and workload-policy alerts.
- [Recover a qbit_manage mistaken clean](runbooks/qbit-manage-mistaken-clean.md) — Contain qbit_manage and restore one mistaken cleanup safely.
- [Recover the platform after workstation or cluster loss](runbooks/platform-disaster-recovery.md) — Restore workstation, identity, node, network, GitOps, storage, and application state in dependency order.

## Specifications

- [001 — Lidarr Music Stack](specs/001-lidarr-music-stack.md) — Describes the implemented music automation design and its media-stack integration.
- [002 — Movie Encoding LA-ICQ Evaluation](specs/002-movie-encoding-la-icq-evaluation.md) — Records the completed LA-ICQ no-go evaluation, evidence, and reconsideration conditions.
- [003 — Tautulli Plex Analytics](specs/003-tautulli-plex-analytics.md) — Describes the implemented Tautulli analytics, persistence, routing, and integration design.
- [004 — Agent Runtime Policy](specs/004-agent-runtime-policy.md) — Explains the rationale for the repository's agent authority and safety boundaries.
- [005 — Flux Reconciliation Alerting](specs/005-flux-reconciliation-alerting.md) — Describes readiness alerts for Flux-managed resources and sources.
- [006 — Media Stack Architecture](specs/006-media-stack-architecture.md) — Describes the shared storage, networking, security, and dependency model for media applications.
- [007 — ntfy Notification Architecture](specs/007-ntfy-notification-architecture.md) — Describes the private notification service and authenticated producer and consumer paths.
- [008 — Plex Relay and Sonos Integration](specs/008-plex-relay-sonos.md) — Records the retained Relay fallback, Sonos boundary, and Plex workload controls.
- [009 — Portainer GitOps Observability](specs/009-portainer-gitops-observability.md) — Describes Portainer's read-only observability design within GitOps authority boundaries.
- [010 — Talos and Flux Platform](specs/010-talos-flux-platform.md) — Describes the implemented three-node Talos, Flux, networking, and storage architecture.
- [011 — Test Reporting Standard](specs/011-test-reporting-standard.md) — Defines the implemented assurance, evidence, catalog, campaign, and reporting design.
- [012 — Plex Public Envoy Experiment](specs/012-plex-public-envoy-experiment.md) — Records the retired public Envoy design, failed Sonos result, and reconsideration conditions.
- [013 — Plex Direct Remote Access](specs/013-plex-direct-remote-access.md) — Describes the current Plex router exposure, identity, containment, and rollback design.
- [014 — Plex Remote-Access Detection](specs/014-plex-remote-access-detection.md) — Describes Hubble-based aggregate detection for sustained off-cluster Plex traffic.
- [015 — Alerting Architecture](specs/015-alerting-architecture.md) — Describes rule ownership, validation coverage, routing, and focused workload-policy alerts.
- [016 — Cert-manager Staging Retirement](specs/016-cert-manager-staging-retirement.md) — Records why permanent staging resources were removed and the production certificate boundary.
- [017 — FileFlows QSV HEVC ICQ Evaluation](specs/017-fileflows-qsv-hevc-icq-evaluation.md) — Describes the ICQ benchmark design, diagnostics, quality gates, evidence contract, and dated corrective amendments.
- [018 — Media Integration Health Collector](specs/018-media-integration-health-collector.md) — Records the unimplemented collector design, its active-probe correction, and why Gatus replaced it.
- [019 — Media Integration Health with Gatus](specs/019-media-integration-health-gatus.md) — Records the implemented Gatus design and its final authenticated API-reachability semantics.
- [020 — Documentation Lifecycle Migration](specs/020-documentation-lifecycle-migration.md) — Describes the migration from legacy lifecycle records to the current documentation structure.
- [021 — Repository Command Lifecycle](specs/021-repository-command-lifecycle.md) — Defines command semantics, safeguards, authority separation, and the approved targeted harmonization.
- [022 — Grafana Alloy and Loki Centralized Logging](specs/022-grafana-alloy-loki.md) — Defines centralized Kubernetes, Talos, and Event logging through Alloy, Loki, and Grafana.
- [023 — n8n Workflow Automation Platform](specs/023-n8n-workflow-automation-platform.md) — Describes the n8n platform, private access, public webhook boundary, persistence, and recovery design.
- [024 — CI Runtime and Merge-Throughput Optimization](specs/024-ci-runtime-and-merge-throughput-optimization.md) — Describes the staged CI optimization design and its validation requirements.
- [025 — Node Lifecycle and Maintenance](specs/025-node-lifecycle-and-maintenance.md) — Defines guarded node disruption, maintenance, and recovery acceptance across Talos, Kubernetes, and Longhorn.
- [026 — Automation Data PostgreSQL Platform](specs/026-automation-data-postgresql-platform.md) — Records the shared workflow database, provisioning, backup, monitoring, and acceptance evidence.
