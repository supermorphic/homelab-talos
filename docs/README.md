# Documentation

Start with a guide for an operator task, a reference for current facts, a runbook
for an unexpected event, or a numbered specification for design rationale.
Current source and `AGENTS.md` remain authoritative for implementation and policy.

## Guides

- Repository work: [worktrees and pull requests](guides/repository-worktree-setup.md),
  [agent cluster access](guides/agent-cluster-access.md),
  [SOPS secrets](guides/sops-secret-operations.md),
  [GitHub main protection](guides/github-main-protection.md), and
  [test campaigns](guides/test-campaign-operations.md).
- Platform services: [OpenBao](guides/openbao-operations.md),
  [Pi-hole and ExternalDNS](guides/pihole-externaldns-operations.md),
  [Tailscale setup](guides/tailscale-initial-setup.md),
  [Tailscale Operator](guides/tailscale-operator-operations.md),
  [private lab-domain access](guides/tailscale-lab-domain-access.md),
  [ntfy](guides/ntfy-operations.md), and
  [Portainer](guides/portainer-operations.md).
- [Credential discovery for approved work](guides/nocodb-operations.md#credential-discovery-for-approved-work): task identities, readiness, and supported helpers.
- Applications: [automation-data PostgreSQL](guides/automation-data-operations.md),
  [n8n](guides/n8n-operations.md), [NocoDB](guides/nocodb-operations.md),
  [media startup](guides/media-automation-setup.md),
  [qBittorrent VPN](guides/qbittorrent-vpn-operations.md),
  [qbit_manage](guides/qbit-manage-operations.md),
  [Plex remote access](guides/plex-remote-access-operations.md), and
  [Plex detection test](guides/plex-remote-access-detection-test.md).

## Reference

- [Repository command lifecycle](reference/repository-command-lifecycle.md)
- [Disruption coordination](reference/disruption-coordination.md)
- [NUC Talos cluster](reference/nuc-cluster.md)
- [Testing layers](reference/testing-layers.md) and
  [persistent test reports](reference/test-reports.md)
- [qbit_manage policy](reference/qbit-manage.md) and
  [CZTeam rules](reference/qbit-manage-czteam.md)

## Runbooks

- [Platform disaster recovery](runbooks/platform-disaster-recovery.md)
- [Plex network alerts](runbooks/plex-network-alerts.md)
- [Mistaken qbit_manage cleanup](runbooks/qbit-manage-mistaken-clean.md)

## Specifications

Numbered records in [`specs/`](specs/) explain design decisions. Current platform
records include [Talos and Flux](specs/010-talos-flux-platform.md),
[test reporting](specs/011-test-reporting-standard.md),
[repository command lifecycle](specs/021-repository-command-lifecycle.md), and
[OpenBao](specs/030-openbao-kubernetes-credential-broker.md). Use the directory to
find application-specific records.
