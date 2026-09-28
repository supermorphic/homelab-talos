# Homelab Talos Platform

This repository is the source of truth for the three-node NUC Talos
cluster and its Flux-managed Kubernetes platform. Start with the
[documentation index](docs/README.md), then use the source-adjacent `README.md`
for the subsystem being changed. Numbered [design specifications](docs/specs/)
record design rationale. Transient implementation plans, when needed, remain
uncommitted under `.tmp/plans/`.

Repository contribution and agent policy is in [`AGENTS.md`](AGENTS.md).
Greenfield qBittorrent, Prowlarr, Sonarr, Radarr, Lidarr, and Seerr UI
configuration is documented in the
[media automation startup guide](docs/guides/media-automation-setup.md).
The [n8n operations guide](docs/guides/n8n-operations.md) covers its private bootstrap,
exact public webhook, controlled assurance, rollback, and recovery choice. The
[platform disaster recovery runbook](docs/runbooks/platform-disaster-recovery.md#n8n--automation-data-recovery)
identifies the shared recovery roots and storage boundary.
The [NocoDB operations guide](docs/guides/nocodb-operations.md) covers the staged private
operator UI, domain source adoption, targeted rotation, failure decisions, and attended
acceptance. The [platform disaster recovery runbook](docs/runbooks/platform-disaster-recovery.md#nocodb-metadata-recovery)
identifies NocoDB recovery roots and the lost-key boundary.

## Contributing and validation

`main` is the Flux production deployment boundary. Changes enter through protected
pull requests. Follow the [repository and worktree guide](docs/guides/repository-worktree-setup.md#prepare-validate-and-publish-a-change)
for preparation, focused checks, rebases, and PR updates. [`AGENTS.md`](AGENTS.md)
defines repository policy and authority boundaries.

GitHub plans affected, cluster-independent validation groups for each pull request.
The required `merge-gate` reconciles their results for the current candidate and base.
Local `mise exec -- just ci` runs the complete offline suite when useful; it is
optional for routine PRs. See [test framework details](tests/README.md#deterministic-ci-groups-and-ownership-checks)
and the [GitHub protection guide](docs/guides/github-main-protection.md).

For live assurance, use the [test campaign guide](docs/guides/test-campaign-operations.md)
for cadence, recorded acceptance, publication, and campaign procedures. The
[agent cluster-access guide](docs/guides/agent-cluster-access.md) covers task-scoped
credentials.

## Physical KVM Note

When connecting the KVM's HDMI and USB cables, `nuc1` and `nuc3` can use their
rear USB-A ports normally. The rear USB-A port on `nuc2` does not provide working
keyboard and mouse access. For `nuc2`, connect the KVM's USB-A cable through a
USB-A-to-USB-C adapter and use the rear USB-C port instead.

## Prerequisites

- macOS with Homebrew and Git
- Bash `>= 5` (`brew install bash`). Recipes use `#!/usr/bin/env bash`, and macOS's
  built-in `/bin/bash` 3.2 silently skips `set -e` for a failed `[[ ]]` test, so
  validation assertions would not gate under it. Bash is a platform prerequisite
  because mise has no supported Bash runtime entry; the `require-bash` guard refuses
  to run validation and verification recipes on an older Bash.
- Access to this repository
- The repository age identity from the operator's password manager when working with
  secrets
- Network access to GitHub and upstream release registries when installing tools

No Kubernetes, Talos, Helm, Flux, or SOPS CLI should be installed manually for
this repository. Mise installs the versions declared in `.mise.toml` and verified
by `mise.lock`.

## First Clone

Install mise, review and trust the repository configuration, install the locked
tools, and validate the checkout:

```bash
brew install mise bash
mise trust
mise install --locked
mise exec -- just repo validate
```

`mise install --locked` is required on the first clone because `just` is itself a
mise-managed tool. After that bootstrap, use Just for repository workflows.

## Shell Setup

Choose one command style for each shell session.

Activate mise, then call Just directly:

```bash
eval "$(mise activate zsh)"
just repo validate
```

Or leave the shell unchanged and execute Just inside the mise environment:

```bash
mise exec -- just repo validate
```

Run `just` or `mise exec -- just` to list the command namespaces. Run a namespace
without a recipe, such as `just talos`, to list its workflows.

## Mise Versus Just

Mise owns tool installation, exact version selection, and the execution
environment. Just is the sole operational task runner; mise tasks are not used.

| Action | Command |
|---|---|
| Bootstrap tools on a new clone | `mise install --locked` |
| Refresh already-bootstrapped tools | `just repo tools` |
| Inspect active tool versions | `just repo versions` or `mise ls --current` |
| Diagnose mise itself | `mise doctor` |
| Run a repository workflow | `just <namespace> <recipe>` |
| Run an ad hoc pinned CLI for investigation | `mise exec -- <tool> ...` |

Prefer a Just recipe whenever one exists. Direct `talosctl`, `kubectl`, `helm`,
`flux`, or `sops` commands are for investigation, recovery documentation, or
developing a new guarded recipe.

## Just Command Reference

The namespace commands are also the built-in command index:

| Command | Purpose |
|---|---|
| `just` | List all top-level namespaces |
| `just repo` | List repository workflows |
| `just talos` | List Talos workflows |
| `just bootstrap` | List staged bootstrap workflows |
| `just node` | List established-node lifecycle workflows |
| `just cluster` | List established-cluster observation workflows |
| `just kube` | List Kubernetes rendering, validation, and live-status workflows |
| `just test` | List test, campaign, and report workflows |

Run `mise exec -- just <namespace>` for the current recipes and their descriptions.
Use the source-adjacent README and [operating guides](docs/README.md#guides) for inputs,
confirmations, and procedure details. [`AGENTS.md`](AGENTS.md) defines execution authority;
the [command lifecycle reference](docs/reference/repository-command-lifecycle.md)
explains command effects and confirmation behavior.

## Operational notes

### ReadWriteOnce volumes require the `Recreate` deployment strategy

**Symptom:** an app update hangs — the new pod sits in `ContainerCreating` with a
`Multi-Attach error for volume`, the Helm upgrade times out, its retries exhaust,
and the HelmRelease wedges in a failed state (often auto-rolling-back).

**Cause:** a `Deployment` that mounts a `ReadWriteOnce` PVC (the default Longhorn
access mode) with the default `RollingUpdate` strategy. RollingUpdate starts the
new pod *before* deleting the old one, but a RWO volume can only attach to one
node at a time, so the new pod can never mount it. This bites on **every** update
to such a workload, not the first install. Hand-deleting pods mid-upgrade makes it
worse — the volume churn can leave the app unable to open its on-disk state.

**Fix (choose per workload):**
- *Stateless-tolerant* (dashboards, status pages): use ephemeral storage and no
  PVC. Gatus uses `storage.type: memory` — uptime history resets on restart,
  which is fine and removes the failure mode entirely.
- *Durable single-writer state:* set the Deployment to `Recreate` (Grafana:
  `grafana.deploymentStrategy.type: Recreate`) so the old pod is deleted before
  the new one starts, or use a StatefulSet (Prometheus/Alertmanager already do).
  `just kube monitoring-validate` asserts Grafana uses `Recreate`.

**Recovering a wedged HelmRelease:** `flux suspend` then `flux resume` the
HelmRelease to reset its retry counter; if the workload is still stuck, delete its
Deployment/PVC (Flux re-applies from Git) or delete the HelmRelease so its
Kustomization reinstalls it fresh. Reconcile changes through Git — never
hand-delete pods mid-rollout.

### Verifying right after a push

`*-verify` recipes call `foundation-verify`/`flux-verify`, which require the live
Flux artifact to equal `origin/main`. Immediately after `git push`, Flux has not
pulled yet and the just-changed Kustomizations briefly flip to not-Ready, so a
verify can fail transiently. Force the pull and wait first:
`flux reconcile source git flux-system` then
`kubectl -n flux-system wait --for=condition=Ready kustomization/<name>`. Running
verify as the tail of `just bootstrap <app>` avoids this (it reconciles
`--with-source` before verifying).

The guarded Talos installation procedure is in [`talos/README.md`](talos/README.md).
The Cilium bootstrap and Flux adoption boundary is in the
[Cilium README](kubernetes/apps/kube-system/cilium/README.md), and the current Flux
source boundary is in [`kubernetes/README.md`](kubernetes/README.md). The
[Talos and Flux platform specification](docs/specs/010-talos-flux-platform.md)
records the architecture rationale. Current Pi-hole and Portainer procedures are in
the [Pi-hole guide](docs/guides/pihole-externaldns-operations.md) and
[Portainer operations guide](docs/guides/portainer-operations.md).

## Daily Cluster Health Check

From the repository root, run these two read-only checks:

```bash
mise exec -- just kube cilium-status
mise exec -- just kube cilium-postflight
```

Begin with the aggregate Flux view:

```bash
mise exec -- just kube flux-status
```

Include the foundation view in the daily check:

```bash
mise exec -- just kube foundation-status
```

If the mise environment is already activated, omit `mise exec --`. A healthy
result shows:

- Helm release `cilium` deployed at `1.19.6`.
- `nuc1`, `nuc2`, and `nuc3` in Kubernetes `Ready` state.
- Three ready Cilium agents, two ready operators, and one ready Hubble Relay.
- Cilium and Hubble reporting `OK` without crash loops or an unexpected restart
  increase.
- No temporary `cilium-test*` namespaces.
- No Talos diagnostics on any node.
- Three etcd members and no etcd alarms.
- Four healthy Flux controllers and all sources,
  Kustomizations, and HelmReleases reporting Ready.
- Ready production issuer, the wildcard certificate, MetalLB,
  Envoy Gateway, ExternalDNS, and echo; Pi-hole resolves the echo hostname to
  `192.168.90.30`.

If either command fails, use the read-only checks in this order:

```bash
# Focused Talos diagnostic resources from every node
mise exec -- just kube cilium-diagnostics

# Etcd membership, Talos service state, discovery, and recent logs
mise exec -- just cluster status

# Limit the detailed output to one node when the failure is localized
mise exec -- just cluster status nuc1
```

Run read-only acceptance first. After a networking change, run the explicit
state-changing functional suite:

```bash
mise exec -- just kube cilium-verify
CILIUM_CONNECTIVITY_CONFIRM='test:cilium-connectivity' \
  mise exec -- just kube cilium-connectivity-test
```

The connectivity test takes approximately 15–20 minutes. It creates temporary test
workloads, exercises DNS, services, policy, FQDN, L7, pod, node, and cross-node
traffic, and removes the test resources afterward. `just kube cilium-validate`
and `just repo validate` validate local declarative sources; they do not establish
live cluster health.

Use `just cluster verify` as the routine established-cluster gate. The separate
pre-Cilium gate is private to bootstrap and intentionally expects all nodes to be
`NotReady`. Do not use `just bootstrap cilium` as a status command because it is an
installation/reconciliation workflow with a guarded mutation path.

## Secret Access

Retrieve the repository age identity from the operator's password manager and expose it
to the current shell. Do not create the key file inside this repository.

For a short session:

```bash
printf 'SOPS age private key: '
read -rs SOPS_AGE_KEY
printf '\n'
export SOPS_AGE_KEY
mise exec -- just repo secrets
```

`SOPS_AGE_KEY` must be exported: an unexported shell variable is not visible to
`mise exec`, `just`, or `sops`. Unset it when the operation is complete.

For repeated operations, use an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just repo secrets
```

`just repo secrets` derives the public recipient and rejects the wrong identity. See the
[SOPS guide](docs/guides/sops-secret-operations.md) for secret-handling procedures and the
[platform disaster-recovery runbook](docs/runbooks/platform-disaster-recovery.md) for
restoring access after workstation or cluster loss.

## Updating Tool Versions

Tool upgrades are deliberate repository changes:

1. Edit the version in `.mise.toml`.
2. Run `mise install` to install the new version.
3. Run `mise lock` to refresh cross-platform URLs, checksums, and provenance.
4. Run `just repo versions` and `just repo validate`.
5. Review and commit `.mise.toml` and `mise.lock` together.

Use `mise install --locked` when consuming the repository. Use unlocked
`mise install` only while intentionally changing the tool definition and lockfile.

## Repository Boundaries

- `talos/` holds declarative Talhelper inputs and its current source documentation.
- `.talos/config` holds the ignored Talos API client credential: the main clone's
  admin identity is generated from encrypted Talhelper source, while the location-aware
  workflow gives a linked worktree only an `os:reader` identity.
- `.kube/config` holds the ignored Kubernetes credential: the main clone receives
  the admin identity retrieved through the Talos machine API, while a linked
  worktree receives only observer and diagnostic ServiceAccount contexts.
- `.just/` holds repository and cross-domain bootstrap command modules.
- `scripts/lib/common.sh` holds validator-safe shared shell helpers;
  `scripts/lib/network.sh` holds shared network constants (the Pi-hole resolver
  IP, the internal Gateway VIP) for host-run scripts; `scripts/lib/rollout.sh` holds operator
  rollout guards; `scripts/validate/` holds the cluster-independent validators
  invoked by Just recipes.
- `talos/mod.just` and `kubernetes/mod.just` colocate domain commands with their
  declarative sources; the root `.justfile` only declares namespaces.
- `clusterconfig/` holds only the three ignored rendered Talos machine configs.
- `kubernetes/` holds Flux sources and source-adjacent subsystem documentation.
- [`docs/`](docs/README.md) links current guides, references, runbooks, and numbered
  design specifications.
- `.tmp/plans/` holds uncommitted transient implementation plans when a task needs one.

The repo-local `.talos/config` and `.kube/config` paths intentionally do not rely
on the CLIs' `$HOME` defaults or ambient current contexts. Guarded recipes always
pass the selected credential path explicitly.

Each checkout has its own ignored credential directories, and credential
installation depends on which checkout runs the command:

- main clone + `mise exec -- just talos kubeconfig` -> admin Kubernetes credential
- worktree + `mise exec -- just talos kubeconfig` -> observer/diagnostic
  Kubernetes contexts and `os:reader` Talos credential
- new worktree -> no credential until the command runs in that worktree
- expired token/certificate -> rerun the same command in that worktree

The worktree path uses the main clone's admin credentials only to mint scoped
credentials; it never copies an admin user into the worktree kubeconfig. Do not
copy credentials into Git.

Generated configs, kubeconfigs, talosconfigs, decrypted secrets, Helm output,
support bundles, and age private identities must remain outside Git, regardless of
repository visibility.
