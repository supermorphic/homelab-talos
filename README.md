# Homelab Talos Platform

This private repository is the source of truth for the three-node NUC Talos
cluster and its Flux-managed Kubernetes platform. The cluster is being rebuilt
from scratch on new NVMe drives; the old manual Talos layout remains only as a
reference and rollback record.

The canonical design and rollout order are in
[`plans/talos-flux-platform-plan.md`](plans/talos-flux-platform-plan.md). Start
there before enabling a new phase. Physical preflight evidence is in
[`docs/phase-0-preflight.md`](docs/phase-0-preflight.md).
Greenfield qBittorrent, Prowlarr, Sonarr, Radarr, and Seerr UI configuration is
documented in [`docs/arr-stack-startup.md`](docs/arr-stack-startup.md).

## Development workflow

`main` is the Flux **production deployment boundary** — Flux reconciles it onto the
live cluster — so changes go through a branch and a pull request, not direct commits
to `main`:

```bash
git fetch origin
git switch -c feat/<short-description> origin/main
# ... make changes ...
mise exec -- just ci            # cluster-independent, secret-free validation gate
git add -A && git commit -m "..."
git push -u origin HEAD
gh pr create
```

`just ci` is the single validation contract — the same command runs locally and in
GitHub Actions ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) on every PR
and push to `main`. It needs the mise toolchain and network egress (Helm pulls
public charts) but **no kubeconfig, SOPS age key, or cluster access**. Cluster-
dependent checks (`*-verify`, `*-status`, `bootstrap`, `pihole-status`) remain
local/operator-only. Squash-merge once the `ci` check is green; emergency
direct-to-`main` commits are exceptional and must be followed by `just ci` on `main`.

AI agents follow the same rules via [`AGENTS.md`](AGENTS.md) (canonical) and
[`CLAUDE.md`](CLAUDE.md) (a thin `@AGENTS.md` adapter).

### Agent-driven PR loop

Most changes are made by an AI agent. The division of labor:

| Step | Who |
|---|---|
| Plan approval (substantial or cross-cutting changes only) | agent proposes → **you approve** |
| Branch → changes → staged commits → `just ci` → push → open PR | agent |
| Review the PR diff and the green `ci` check | **you** |
| Squash-merge | **you** |
| Flux reconciles `main`; run guarded `just bootstrap …` rollouts | Flux / **you** |

The agent owns branch-through-open-PR; you own review, merge, and rollout. The
agent **never self-merges** and **never runs live cluster rollouts unprompted** —
cluster-mutating `bootstrap …` recipes stay behind operator `*_CONFIRM` gates.
Because merging to `main` deploys via Flux, the PR plus a green `ci` check is the
review gate before anything reaches the cluster; branch protection makes that gate
mandatory rather than conventional.

### Parallel agent worktrees

To run several agents at once, give each one a **reusable worktree slot** — a
persistent linked worktree that lives beside this repo. You (the operator) own the
worktree lifecycle; the agent only manages branches, commits, and PRs *inside* the
slot. The agent-side rules are in [`AGENTS.md`](AGENTS.md) → "Git worktrees".

**You: create the slots once.** From the primary checkout:

```bash
cd /Users/ksiggins/Development/homelab-talos
git fetch origin
git worktree add --detach ../homelab-talos-agent-1 origin/main
git worktree add --detach ../homelab-talos-agent-2 origin/main
git worktree add --detach ../homelab-talos-agent-3 origin/main
```

`--detach` starts each slot on a detached `origin/main` with no branch checked out —
the agent creates its own feature branch on its first task, so the slots never
collide over a branch name.

List every worktree (primary checkout plus slots) with:

```bash
git worktree list
```

**You: open each slot in its own VS Code window.** For each slot:

1. Open the Command Palette with `Cmd+Shift+P` (or select **File → New Window**).
2. In the new window, select **File → Open Folder…**.
3. Select the worktree directory, e.g. `homelab-talos-agent-1`.

VS Code automatically recognizes the folder as a linked Git worktree.

**The agent, per task, inside a slot:** creates a feature branch off `origin/main`
(or resumes an existing one), makes changes, runs `just ci`, commits, pushes, and
opens the PR. It never touches the worktree itself, never switches the slot to
`main`, and never self-merges.

Because other worktrees may merge concurrently, the agent fetches `origin` before
final validation and again immediately before each push. If `origin/main` is no
longer an ancestor of the feature branch, it rebases onto the new `origin/main`,
reruns `mise exec -- just ci`, and repeats the check. An already-published branch is
updated after that rebase with `--force-with-lease` only; a failed lease is treated
as unexpected remote work and stops the update.

**Operator rollouts may also run inside a feature worktree.** A guarded
`mise exec -- just bootstrap …` recipe does not require the checked-out branch to
be `main`. Before rollout, run `git fetch origin main` and leave the worktree clean.
The guard compares its own rollout implementation and the exact source paths it
will reconcile with the fetched commit currently published at remote
`origin/main`. It refuses local changes to those paths, while allowing committed
feature work elsewhere in the tree. Flux still reconciles only `main`; branch
independence changes where the command may run, not what is allowed to deploy.
This is a fail-closed drift check for a trusted operator checkout, not
tamper-resistant attestation of the helper already executing; pull-request review
and branch protection remain the source-integrity controls.

**You: after review, squash-merge the PR.** Then either:

- **Start fresh** — tell the agent to begin a new task; it deletes the merged branch
  and branches again off `origin/main`. The worktree and its VS Code window stay put.
- **Continue on the same branch** — e.g. a follow-up before merge, or more work after
  merge; the agent stays on the branch. No worktree change either way.

**You: retire a slot when you're done with it.** Close its VS Code window, then
remove the worktree from the primary checkout:

```bash
git worktree remove ../homelab-talos-agent-1        # add --force if it refuses on leftover files
git worktree prune                                  # tidy stale metadata if needed
```

Deleting a slot's directory by hand leaves dangling metadata — always use
`git worktree remove`.

## Physical KVM Note

When connecting the KVM's HDMI and USB cables, `nuc1` and `nuc3` can use their
rear USB-A ports normally. The rear USB-A port on `nuc2` does not provide working
keyboard and mouse access. For `nuc2`, connect the KVM's USB-A cable through a
USB-A-to-USB-C adapter and use the rear USB-C port instead.

## Prerequisites

- macOS with Homebrew and Git
- Bash `>= 4` (`brew install bash`). Recipes use `#!/usr/bin/env bash`, and macOS's
  built-in `/bin/bash` 3.2 silently skips `set -e` for a failed `[[ ]]` test, so
  validation assertions would not gate under it. The `require-bash` guard refuses
  to run the verification recipes on an older bash.
- Access to this private repository
- The password-manager item `homelab-talos SOPS age key` when working with secrets
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
mise exec -- just repo verify
```

`mise install --locked` is required on the first clone because `just` is itself a
mise-managed tool. After that bootstrap, use Just for repository workflows.

## Shell Setup

Choose one command style for each shell session.

Activate mise, then call Just directly:

```bash
eval "$(mise activate zsh)"
just repo verify
```

Or leave the shell unchanged and execute Just inside the mise environment:

```bash
mise exec -- just repo verify
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
| `just kube` | List Kubernetes rendering, validation, and live-status workflows |

All currently defined recipes are listed below. Recipes marked internal are
normally invoked as dependencies of the operator-facing workflow, but remain
available for focused developer validation.

| Recipe | Purpose | Requires from operator | Availability |
|---|---|---|---|
| `just repo tools` | Install locked tools and print versions | — | Available |
| `just repo versions` | Print the active tool versions | — | Available |
| `just repo secrets` | Confirm the loaded age identity matches this repository | `SOPS_AGE_KEY`[`_FILE`] | Available |
| `just repo pihole-status` | Verify Pi-hole HTTPS, tracked CA, and application-session write policy | `p1` SSH access | Enabled in Phase 7; read-only |
| `just repo pihole-ca-refresh` | Guard and refresh only the tracked public Pi-hole CA after reinstall or rotation | `p1` SSH access; `PIHOLE_CA_REFRESH_CONFIRM` | Enabled in Phase 7; mutating tracked public trust source after confirmation |
| `just repo phase7-secrets` | Validate Phase 7 provider credentials and write only encrypted Secret manifests | `SOPS_AGE_KEY`[`_FILE`]; `CLOUDFLARE_API_TOKEN`; `PIHOLE_PASSWORD`; `PHASE7_SECRETS_CONFIRM` | Enabled in Phase 7; mutating tracked ciphertext after confirmation |
| `just repo verify` | Check policy, Talos sources, and tracked content for secrets | — | Available |
| `just repo verify-files` | Check ignore boundaries and SOPS policy | — | Available; internal validation |
| `just repo secret-scan` | Run the repository secret scans directly | — | Available |
| `just talos generate` | Render and validate machine configs with Talhelper | `SOPS_AGE_KEY`[`_FILE`] | Available |
| `just talos validate` | Strictly validate rendered Talos configs and Phase 2 policy | — | Available |
| `just talos source-validate` | Validate trackable Talhelper inputs without decrypting identity | — | Available; internal validation |
| `just talos apply <node>` | Guard, dry-run, and install one node's machine config from maintenance mode (wipes and reboots) | `TALOS_APPLY_CONFIRM` | Enabled in Phase 3; destructive after confirmation |
| `just talos apply-live <node>` | Guard, dry-run, and apply a config change to an already-running node in no-reboot mode (never wipes) | `TALOS_APPLY_LIVE_CONFIRM` | Day-2; mutating after confirmation |
| `just talos volume-status` | Report and verify the longhorn user volume (size, mount, filesystem) and STATE/EPHEMERAL encryption are healthy on every node | — | Day-2; read-only |
| `just talos kubeconfig` | Atomically refresh the ignored workstation kubeconfig at `.kube/config` through Talos (no etcd/NotReady gate) | — | Day-2; the routine way to (re)fetch a kubeconfig after Cilium |
| `just bootstrap resize-longhorn <node>` | Shrink/recreate the longhorn volume to the configured maxSize (release → wipe → reprovision, two reboots) with a full recovery gate | `TALOS_RESIZE_LONGHORN_CONFIRM` | Day-2; destructive after confirmation |
| `just bootstrap preflight` | Verify all three installed NUCs and refuse if etcd is initialized | — | Enabled in Phase 4; read-only |
| `just bootstrap talos` | Guard and bootstrap etcd exactly once on nuc1 | `TALOS_BOOTSTRAP_CONFIRM` | Enabled in Phase 4; destructive after confirmation |
| `just bootstrap status [node]` | Print read-only etcd membership, service, discovery, and recent logs; optionally select one node | — | Enabled in Phase 4; diagnostic |
| `just bootstrap retry-join <node>` | Guard and reboot a failed nuc2/nuc3 etcd join without re-bootstrap | `TALOS_ETCD_RETRY_CONFIRM` | Enabled in Phase 4; mutating after confirmation |
| `just bootstrap verify` | Verify the pre-Cilium etcd/Kubernetes/Talos gate and refresh ignored kubeconfig | — | Historical Phase 4 gate; do not use after Cilium — use `just talos kubeconfig` to fetch a kubeconfig day-2 |
| `just kube cilium-render` | Render the pinned Cilium OCI chart to standard output | — | Enabled in Phase 5; read-only |
| `just kube cilium-validate` | Validate Cilium sources, values, and the Helm render | — | Enabled in Phase 5; read-only |
| `just kube cilium-status` | Print Helm, node, pod, and Cilium status | — | Enabled in Phase 5; read-only |
| `just kube cilium-diagnostics` | Print Talos diagnostics from all cluster nodes | — | Enabled in Phase 5; read-only |
| `just kube cilium-postflight` | Verify test cleanup, Talos diagnostics, and etcd health | — | Enabled in Phase 5; read-only |
| `just kube cilium-verify` | Run the Phase 5 gate and temporary connectivity tests | — | Enabled in Phase 5; creates and removes test resources |
| `just bootstrap cilium` | Guard and install or reconcile Cilium `1.19.6` | `CILIUM_BOOTSTRAP_CONFIRM` | Enabled in Phase 5; mutating after confirmation |
| `just kube flux-validate` | Validate Flux sources, SOPS canary, dependencies, and Cilium adoption guards | — | Enabled in Phase 6; read-only |
| `just kube flux-preflight` | Verify published Git, Cilium/Talos/etcd health, and Kubernetes compatibility | — | Enabled in Phase 6; read-only |
| `just bootstrap flux` | Bootstrap Flux `2.9.2` and a read-only GitHub SSH deploy key | `GITHUB_TOKEN`; `FLUX_BOOTSTRAP_CONFIRM` | Enabled in Phase 6; mutating after confirmation |
| `just bootstrap flux-sops` | Create or verify the matching in-cluster SOPS identity | `SOPS_AGE_KEY`[`_FILE`]; `FLUX_SOPS_CONFIRM` | Enabled in Phase 6; mutating after confirmation |
| `just bootstrap flux-ssh-known-hosts` | Preserve the deploy key and repair GitHub port-443 host trust | `FLUX_SSH_KNOWN_HOSTS_CONFIRM` | Phase 6 recovery; mutating after confirmation |
| `just bootstrap flux-adopt-cilium` | Adopt Cilium with guarded workload health and stage the permanent unsuspend | `FLUX_CILIUM_ADOPTION_CONFIRM` | Enabled in Phase 6; mutating after confirmation |
| `just kube flux-status` | Print Flux controllers and reconciliation state | — | Enabled in Phase 6; read-only |
| `just kube flux-verify` | Verify Flux source auth, SOPS, canary, Cilium, Talos, and etcd | — | Enabled in Phase 6; read-only |
| `just kube flux-canary-test` | Prove Flux recreates the guarded noncritical canary Secret | `FLUX_CANARY_CONFIRM` | Enabled in Phase 6; mutating after confirmation |
| `just kube foundation-validate` | Validate Phase 7 sources, encrypted providers, dependency policy, and pinned chart renders | — | Enabled in Phase 7; read-only |
| `just kube foundation-status` | Print certificate, MetalLB, Gateway, ExternalDNS, and echo state | — | Enabled in Phase 7; read-only |
| `just bootstrap foundation` | Reconcile the nine staged foundation units in guarded dependency order | `SOPS_AGE_KEY`[`_FILE`]; `PHASE7_NETWORK_CONFIRM`; `PHASE7_BOOTSTRAP_CONFIRM` | Enabled in Phase 7; mutating after confirmation |
| `just kube foundation-verify` | Verify DNS, trusted HTTPS, echo, Cilium, Talos, and etcd acceptance | — | Enabled in Phase 7; read-only |
| `just bootstrap reboot <node>` | Gate on cluster health, reboot one node, and require full recovery (TPM auto-unlock, etcd, MetalLB failover, Cilium, DNS, HTTPS) | `TALOS_REBOOT_CONFIRM` | Enabled in Phase 8; disruptive after confirmation |
| `just kube flux-restart` | Restart the flux-system controllers and prove reconciliation resumes | `FLUX_RESTART_CONFIRM` | Enabled in Phase 8; mutating after confirmation |
| `just repo storage-secrets` | Validate the UNAS CIFS credentials and write only the encrypted Longhorn backup Secret | `SOPS_AGE_KEY`[`_FILE`]; `CIFS_USERNAME`; `CIFS_PASSWORD`; `STORAGE_SECRETS_CONFIRM` | Enabled in Phase 9; mutating tracked ciphertext after confirmation |
| `just kube storage-validate` | Validate the Longhorn source, encrypted CIFS Secret, backup-target CR, dependencies, and pinned chart render | — | Enabled in Phase 9; read-only |
| `just bootstrap storage` | Reconcile the staged Longhorn Kustomizations in dependency order and run the acceptance gate | `STORAGE_BOOTSTRAP_CONFIRM` | Enabled in Phase 9; mutating after confirmation |
| `just kube storage-verify` | Verify Longhorn health, node disks, default StorageClass, backup target, recurring jobs, and a two-replica test PVC | — | Enabled in Phase 9; creates and removes a test PVC |
| `just ci` | Run the cluster-independent, secret-free validation gate (lint + verify + kubeconform + all `*-validate`) | — | Local + GitHub Actions; the PR gate |
| `just test validate` | Lint Chainsaw configuration/tests, enforce read-only smoke policy, parse test YAML, and check test scripts | — | Cluster-independent; included in `just ci` |
| `just test smoke cluster` | Run the read-only Flux readiness proof and write evidence under `.test-results/` | `.kube/config` | Operator-only; never in `just ci` |
| `just test smoke cluster diagnostics-self-test` | Deliberately fail a read-only assertion to prove catch/fallback diagnostics and failure preservation | `.kube/config` | Operator-only; expected failure |
| `just test diagnostics cluster` | Collect allowlisted Flux, Pod, and Event diagnostics without Secret bodies | `.kube/config` | Operator-only; read-only |
| `just test e2e <target>` | Run an allowlisted state-changing functional scenario under a single-run lock | `.kube/config` | Fails closed until a target is registered |
| `just test resilience <target>` | Run an allowlisted disruptive recovery scenario under confirmation and locking guards | `.kube/config`; `CLUSTER_CHAOS_CONFIRM=chaos:<target>` | Fails closed until a target is registered |
| `just repo hooks` | Install the git pre-commit hooks (idempotent) | — | Available |
| `just repo lint` | Run all pre-commit hooks against the tree | — | Available |
| `just kube kubeconform` | Validate the built app manifests against Kubernetes + CRD schemas | — | Available; read-only, fetches schemas over HTTPS |
| `just kube foundation-ca-expiry` | Warn if the committed Pi-hole CA is within 30 days of expiry | — | Operational; time-based, kept out of `just ci` |
| `just kube metrics-server-validate` | Validate the metrics-server source, insecure-TLS flag, and pinned render | — | Available; read-only |
| `just bootstrap metrics-server` | Reconcile the staged metrics-server and verify (`kubectl top`, HPA, Homepage widget) | `METRICS_SERVER_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just kube metrics-server-verify` | Verify metrics-server: APIService Available and `kubectl top nodes` returns data | — | Read-only |

The **Requires from operator** column lists inputs the recipe reads from your
environment and refuses to run without. `SOPS_AGE_KEY`[`_FILE`] means either the
key value or a path to it. `*_CONFIRM` values are the exact confirmation strings
each guarded recipe prints when refused. Secrets and confirmations are never
stored in `.mise.toml`; recipes fail fast when they are absent.

Future-phase cluster mutations are added only with their validation, guard, and
documentation boundary. Do not replace a missing workflow with an ad hoc apply.

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

The Phase 3 apply procedure, including its exact serial-bound confirmation, is
documented in [`talos/README.md`](talos/README.md) and the installation evidence
is recorded in [`docs/phase-3-installation.md`](docs/phase-3-installation.md).
The Cilium ownership boundary, exact confirmation, connectivity test, and Phase 5
evidence are documented in
[`docs/phase-5-cilium.md`](docs/phase-5-cilium.md).
The Flux credential model, staged Cilium adoption, exact confirmations, and
Phase 6 acceptance gate are in
[`docs/phase-6-flux.md`](docs/phase-6-flux.md). Phase 7 credentials, rollout,
failure behavior, and acceptance gates are in
[`docs/phase-7-foundation.md`](docs/phase-7-foundation.md). Pi-hole fresh-install,
CA rotation, and application-password recovery are in
[`docs/pihole-integration.md`](docs/pihole-integration.md).

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

After Phase 7 is installed, add the foundation view to the daily check:

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
- Ready staging and production issuers, the wildcard certificate, MetalLB,
  Envoy Gateway, ExternalDNS, and echo; Pi-hole resolves the echo hostname to
  `192.168.90.30`.

If either command fails, use the read-only checks in this order:

```bash
# Focused Talos diagnostic resources from every node
mise exec -- just kube cilium-diagnostics

# Etcd membership, Talos service state, discovery, and recent logs
mise exec -- just bootstrap status

# Limit the detailed output to one node when the failure is localized
mise exec -- just bootstrap status nuc1
```

Run the full functional network suite after a networking change or when the
status checks cannot explain a connectivity problem:

```bash
mise exec -- just kube cilium-verify
```

The full verifier takes approximately 15–20 minutes. It creates temporary test
workloads, exercises DNS, services, policy, FQDN, L7, pod, node, and cross-node
traffic, and removes the test resources afterward. `just kube cilium-validate`
and `just repo verify` validate local declarative sources; they do not establish
live cluster health.

Do not use `just bootstrap verify` as a routine check after Cilium is installed.
It is the historical Phase 4 pre-CNI gate and intentionally expects all nodes to
be `NotReady`. Do not use `just bootstrap cilium` as a status command because it
is an installation/reconciliation workflow with a guarded mutation path.

## Secret Access

Retrieve `homelab-talos SOPS age key` from the password manager and expose it to
the current shell. Do not create the key file inside this repository.

For a short session:

```bash
printf 'SOPS age private key: '
read -rs SOPS_AGE_KEY
printf '\n'
export SOPS_AGE_KEY
just repo secrets
```

`SOPS_AGE_KEY` must be exported: an unexported shell variable is not visible to
`mise exec`, `just`, or `sops`. Unset it when the operation is complete.

For repeated operations, use an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
just repo secrets
```

`just repo secrets` derives the public recipient and rejects the wrong identity. See
[`docs/sops.md`](docs/sops.md) for encryption policy and
[`docs/recovery.md`](docs/recovery.md) for restoring access.

## Normal Change Workflow

1. Confirm the current phase and its prerequisites in the canonical plan.
2. Run `just repo tools` after pulling a change to `.mise.toml` or `mise.lock`.
3. Load the SOPS identity only when the change requires encrypted material.
4. Edit declarative source files, never generated output.
5. Run the phase-specific generation or validation recipe when it is available.
6. Run `just repo verify` before reviewing or committing the change.
7. Inspect `git status` and confirm no generated config, decrypted secret,
   kubeconfig, talosconfig, or private key is trackable.

Do not bypass a disabled recipe with a raw cluster-changing command. Enable and
test the guarded recipe as part of the phase that owns that operation.

## Updating Tool Versions

Tool upgrades are deliberate repository changes:

1. Edit the version in `.mise.toml`.
2. Run `mise install` to install the new version.
3. Run `mise lock` to refresh cross-platform URLs, checksums, and provenance.
4. Run `just repo versions` and `just repo verify`.
5. Review and commit `.mise.toml` and `mise.lock` together.

Use `mise install --locked` when consuming the repository. Use unlocked
`mise install` only while intentionally changing the tool definition and lockfile.

## Repository Boundaries

- `talos/` holds declarative Talhelper inputs beginning in Phase 2.
- `.talos/config` holds the ignored Talos API client credential generated from the
  encrypted Talhelper identity.
- `.kube/config` holds the ignored Kubernetes admin credential retrieved through
  the Talos machine API.
- `.just/` holds repository and cross-domain bootstrap command modules.
- `scripts/lib/common.sh` holds validator-safe shared shell helpers;
  `scripts/lib/rollout.sh` holds operator rollout guards; `scripts/validate/`
  holds the cluster-independent validators invoked by Just recipes.
- `talos/mod.just` and `kubernetes/mod.just` colocate domain commands with their
  declarative sources; the root `.justfile` only declares namespaces.
- `clusterconfig/` holds only the three ignored rendered Talos machine configs.
- `kubernetes/` holds Flux sources beginning in Phase 5.
- `docs/` holds inventory, recovery, secret handling, and phase evidence.
- `plans/` holds architectural decisions and phased acceptance gates.

The repo-local `.talos/config` and `.kube/config` paths intentionally do not rely
on the CLIs' `$HOME` defaults or ambient current contexts. Guarded recipes always
pass the selected credential path explicitly.

A linked worktree has its own ignored credential directories. Initialize
`.talos/config` either by loading the repository SOPS identity and running
`just talos generate`, or by installing a trusted talosconfig from another
operator checkout with directory mode `0700` and file mode `0600`. Then run
`just talos kubeconfig` to fetch and validate that worktree's `.kube/config`;
do not copy credentials into Git.

Generated configs, kubeconfigs, talosconfigs, decrypted secrets, Helm output,
support bundles, and age private identities must remain outside Git. The private
repository does not weaken this rule.

## Current Phase

Phase 6 is complete: Flux `2.9.2` reconciles the private repository with a
read-only deploy key over SSH port 443, decrypts the permanent SOPS canary,
repairs tested drift, and owns Cilium `1.19.6`. All four Flux Kustomizations are
Ready and unsuspended; Cilium, Talos, and etcd acceptance gates pass. Phase 7 is
complete: cert-manager, MetalLB, Envoy Gateway, and ExternalDNS are reconciled by
Flux, the production wildcard certificate is issued, the internal Gateway is
Programmed at `192.168.90.30`, Pi-hole resolves the echo hostname, and trusted
HTTPS returns the echo response; acceptance evidence and the MetalLB control-plane
label fix are in [`docs/phase-7-foundation.md`](docs/phase-7-foundation.md). Phase 8
is complete: the rolling-reboot, MetalLB failover, Flux-restart, and echo
remove/recreate tests passed and the 24-hour soak held with no regressions
([`docs/phase-8-soak.md`](docs/phase-8-soak.md)) — closing the Phases 0–8
foundation milestone, so the old SSDs are clear to wipe. Phase 9 is complete:
Longhorn `1.12.0` replicated block storage is live with a CIFS backup target
([`docs/phase-9-storage.md`](docs/phase-9-storage.md)); bulk media storage is
deferred to Phase 11 over SMB. See
[`docs/phase-3-installation.md`](docs/phase-3-installation.md) for installation
evidence and [`docs/phase-4-bootstrap.md`](docs/phase-4-bootstrap.md) for the
bootstrap interface and recovery record. Phase 5 commands and live evidence are
in [`docs/phase-5-cilium.md`](docs/phase-5-cilium.md); Flux ownership and Phase 6
acceptance evidence are in [`docs/phase-6-flux.md`](docs/phase-6-flux.md).
