# Homelab Talos Platform

This repository is the source of truth for a three-node Talos Linux and Flux GitOps
Kubernetes cluster. Talos inputs define the nodes; Git and Flux define Kubernetes
resources. SOPS keeps durable secret values encrypted in Git. Merged changes to
`main` can affect the live cluster.

## Start here

- [Documentation index](docs/README.md): operator guides, references, incident
  runbooks, and numbered design specifications.
- [Agent and contributor policy](AGENTS.md): worktree, authority, secret, validation,
  and merge boundaries.
- [Talos source contract](talos/README.md): machine configuration and guarded
  installation.
- [Kubernetes source contract](kubernetes/README.md): Flux layout, dependencies,
  and the Cilium bootstrap boundary.
- [Testing entry point](tests/README.md): catalog, offline CI, and live evidence.
- [Platform disaster recovery](docs/runbooks/platform-disaster-recovery.md): recovery
  roots and dependency order.

For a new checkout on macOS, install Homebrew's `mise` and Bash 5 or newer, then
trust the repository configuration and install its locked tools:

```sh
brew install mise bash
mise trust
mise install --locked
mise exec -- just repo validate
```

The repository pins its tools in `.mise.toml` and `mise.lock`. Run established
workflows with `mise exec -- just …`; `mise exec -- just` lists the available
command namespaces. Operator inputs and decisions belong in the relevant guide.

Agent database tasks start with [credential discovery](docs/guides/nocodb-operations.md#credential-discovery-for-approved-work).

## Changes and assurance

Use an isolated worktree and a pull request for implementation work. The
[repository workflow guide](docs/guides/repository-worktree-setup.md) covers
preparation and publication. Hosted `merge-gate` validates the exact candidate
and base; live tests are separately authorized and recorded through the
[test campaign guide](docs/guides/test-campaign-operations.md).

Source remains authoritative for current behavior. Use the applicable guide or
reference for operator actions and current facts, and a numbered specification
for design rationale. The [NUC cluster reference](docs/reference/nuc-cluster.md)
records physical and network details.
