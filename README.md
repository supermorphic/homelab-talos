# Homelab Talos Platform

This repository is the source of truth for a three-node Talos Linux and Flux GitOps
Kubernetes cluster. Talos inputs define the nodes; Git and Flux define Kubernetes
resources. SOPS keeps durable secrets encrypted in Git. Merges to `main` can affect
the live cluster.

## Bootstrap and commands

For a new macOS checkout, install mise and Bash 5 or newer, then install the locked
toolchain and validate source:

```sh
brew install mise bash
mise trust
mise install --locked
mise exec -- just repo validate
```

`mise exec -- just` lists command namespaces; `mise exec -- just <namespace>` lists
that namespace's commands. Read [AGENTS.md](AGENTS.md) for execution and publication
boundaries. Initial cluster installation and independent recovery start in the
[platform spec](docs/specs/010-talos-flux-platform.md).

For routine database access discovery, start with
`mise exec -- just kube automation-data-credentials --help`; `resolve --help` explains
profile selection, the supported connection, and blocked results.

## Topics

- [Platform and recovery](docs/specs/010-talos-flux-platform.md),
  [node maintenance](docs/specs/025-node-lifecycle-and-maintenance.md).
- [Media](docs/specs/006-media-stack-architecture.md) and
  [alerting](docs/specs/015-alerting-architecture.md).
- [n8n automation](docs/specs/023-n8n-workflow-automation-platform.md),
  [PostgreSQL and credential discovery](docs/specs/026-automation-data-postgresql-platform.md),
  [NocoDB](docs/specs/028-nocodb-operator-ui.md), and
  [web research](docs/specs/029-selfhost-web-research.md).
- [OpenBao recovery](docs/specs/030-openbao-kubernetes-credential-broker.md) and
  [agent credentials](docs/specs/031-openbao-agent-credential-profiles.md).
- [Test evidence](docs/specs/011-test-reporting-standard.md) and
  [CI guarantees](docs/specs/027-deterministic-ci-gates.md).

Read only the owning spec sections needed for the task. Source, configuration, and
command help carry exact implementation facts.
