# Homelab Talos Platform

This private repository is the source of truth for the three-node NUC Talos
cluster and its Flux-managed Kubernetes platform. Start with the
[documentation index](docs/README.md), then use the source-adjacent `README.md`
for the subsystem being changed. Numbered [design specifications](docs/specs/)
record design rationale. Transient implementation plans, when needed, remain
uncommitted under `.tmp/plans/`.

Repository contribution and agent policy is in [`AGENTS.md`](AGENTS.md).
Greenfield qBittorrent, Prowlarr, Sonarr, Radarr, Lidarr, and Seerr UI
configuration is documented in the
[media automation startup guide](docs/guides/media-automation-setup.md).

## Development workflow

`main` is the Flux **production deployment boundary** — Flux reconciles it onto the
live cluster — so every change enters through a protected pull request:

```bash
mise exec -- just repo hooks     # once per clone; installs the commit-time hooks
git fetch origin
git switch -c feat/<short-description> origin/main
# ... make changes ...
git add -A
git commit -m "..."             # staged-file hooks provide fast feedback
git fetch origin
git rebase origin/main           # when main advanced and the branch is clean
git push -u origin HEAD
mise exec -- gh pr create
```

Commit-time pre-commit hooks are the only automatic local gate and inspect staged
files, so install them with `mise exec -- just repo hooks` in every fresh clone —
an uninstalled hook suite silently removes that gate. `mise exec -- just repo lint`
runs the same hook suite repository-wide. The hook recipe installs into Git's shared
common directory and configures `core.hooksPath` to use it. One installation covers the
clone and its linked worktrees; rerunning the recipe from either location is safe.
`mise exec -- just ci` remains the single canonical full validation command and can
be run locally, but the required GitHub Actions `ci` check is the authoritative merge
gate for every pull request targeting `main`. It needs network egress for public Helm
charts but **no kubeconfig, SOPS age key, cluster access, or repository secrets**.

The active `Protect main` ruleset requires the branch to be current, the GitHub
Actions `ci` check to pass, and squash as the only merge method. Actions validates
GitHub's merge candidate; with the strict up-to-date rule, the later squash commit
has different commit identity but the equivalent source tree. The operator reviews
and merges, then Flux reconciles the resulting `main`. See the
[GitHub protection guide](docs/guides/github-main-protection.md) for the applied settings, GitHub
inspection locations, complete verification, and guarded recovery.

### Test cadence and campaigns

Use this cadence so "full test suite" has one unambiguous meaning:

| Cadence | Run | Purpose |
| --- | --- | --- |
| Every PR | `mise exec -- just ci` | Required cluster-independent source gate; GitHub runs this automatically |
| Nightly | `standard` campaign | Validation, smoke, E2E, and quick conformance, with every canonical child uploaded to Allure |
| Weekly | `weekly` campaign | Nightly coverage plus verification, integration, probes, and disruptive resilience |
| Full | `full` campaign | Every implemented assurance suite, including certified conformance; run monthly and around major platform upgrades |

Preview the desired campaign from clean, deployed `origin/main`:

```bash
mise exec -- just test campaign-plan standard
mise exec -- just test campaign-plan weekly
mise exec -- just test campaign-plan full
```

Then run the exact confirmation command printed by its plan:

```bash
TEST_CAMPAIGN_CONFIRM=run-publish:standard \
  mise exec -- just test campaign standard
TEST_CAMPAIGN_CONFIRM='<weekly token printed by campaign-plan>' \
  mise exec -- just test campaign weekly
TEST_CAMPAIGN_CONFIRM='<full token printed by campaign-plan>' \
  mise exec -- just test campaign full
```

The `weekly` and `full` tokens bind the source and plan digest because both include
disruptive recovery and a Plex node reboot. Campaigns capture and publish every child
run automatically. See the [test campaign guide](docs/guides/test-campaign-operations.md) for focused
campaigns, failure behavior, resume, and exact membership.

### Agent workflow

Agents use the development workflow above. Repository authority, credential, live-action,
publication, and merge boundaries are defined only in [`AGENTS.md`](AGENTS.md);
[`CLAUDE.md`](CLAUDE.md) is a thin adapter. The
[agent cluster-access guide](docs/guides/agent-cluster-access.md) describes the current
task-scoped credential procedure.

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
| `just kube` | List Kubernetes rendering, validation, and live-status workflows |

All currently defined recipes are listed below. Recipes marked internal are
normally invoked as dependencies of the operator-facing workflow, but remain
available for focused developer validation.

| Recipe | Purpose | Requires from operator | Availability |
|---|---|---|---|
| `just repo tools` | Install locked tools and print versions | — | Available |
| `just repo versions` | Print the active tool versions | — | Available |
| `just repo secrets` | Confirm the loaded age identity matches this repository | `SOPS_AGE_KEY`[`_FILE`] | Available |
| `just repo pihole-status` | Verify Pi-hole HTTPS, tracked CA, and application-session write policy | `p1` SSH access | Read-only |
| `just repo pihole-ca-refresh` | Guard and refresh only the tracked public Pi-hole CA after reinstall or rotation | `p1` SSH access; `PIHOLE_CA_REFRESH_CONFIRM` | Mutating tracked public trust source after confirmation |
| `just repo foundation-provider-secrets` | Validate foundation provider credentials and write encrypted Secret manifests plus the ExternalDNS rollout stamp | `SOPS_AGE_KEY`[`_FILE`]; `CLOUDFLARE_API_TOKEN`; `PIHOLE_PASSWORD`; `FOUNDATION_PROVIDER_SECRETS_CONFIRM` | Temporary external DNS mutation and tracked source mutation after confirmation |
| `just repo validate` | Check policy, Talos sources, and tracked content for secrets | — | Available |
| `just repo validate-files` | Check ignore boundaries and SOPS policy | — | Available; internal validation |
| `just repo secret-scan` | Run the repository secret scans directly | — | Available |
| `just talos generate` | Render and validate machine configs with Talhelper | `SOPS_AGE_KEY`[`_FILE`] | Available |
| `just talos validate` | Strictly validate rendered Talos configs and current source policy | — | Available |
| `just talos source-validate` | Validate trackable Talhelper inputs without decrypting identity | — | Available; internal validation |
| `just talos apply <node>` | Guard, dry-run, and install one node's machine config from maintenance mode (wipes and reboots) | `TALOS_APPLY_CONFIRM` | Destructive after confirmation |
| `just talos apply-live <node>` | Guard, dry-run, and apply a config change to an already-running node in no-reboot mode (never wipes) | `TALOS_APPLY_LIVE_CONFIRM` | Day-2; mutating after confirmation |
| `just talos volume-status` | Report and verify the longhorn user volume (size, mount, filesystem) and STATE/EPHEMERAL encryption are healthy on every node | — | Day-2; read-only |
| `just talos kubeconfig` | From the main clone, atomically refresh the ignored admin kubeconfig; from a worktree, mint scoped Kubernetes and Talos credentials from the main-clone admin credentials | — | Location-aware credential installation |
| `just bootstrap resize-longhorn <node>` | Shrink/recreate the longhorn volume to the configured maxSize (release → wipe → reprovision, two reboots) with a full recovery gate | `TALOS_RESIZE_LONGHORN_CONFIRM` | Day-2; destructive after confirmation |
| `just bootstrap preflight` | Verify all three installed NUCs and refuse if etcd is initialized | — | Cluster bootstrap; read-only |
| `just bootstrap talos` | Guard and bootstrap etcd exactly once on nuc1 | `TALOS_BOOTSTRAP_CONFIRM` | Cluster bootstrap; destructive after confirmation |
| `just bootstrap status [node]` | Print read-only etcd membership, service, discovery, and recent logs; optionally select one node | — | Diagnostic |
| `just bootstrap retry-join <node>` | Guard and reboot a failed nuc2/nuc3 etcd join without re-bootstrap | `TALOS_ETCD_RETRY_CONFIRM` | Recovery; mutating after confirmation |
| `just bootstrap verify` | Verify the pre-Cilium etcd/Kubernetes/Talos gate and refresh ignored kubeconfig | — | Pre-Cilium bootstrap only; use `just talos kubeconfig` after Cilium |
| `just kube cilium-render` | Render the pinned Cilium OCI chart to standard output | — | Read-only |
| `just kube cilium-validate` | Validate Cilium sources, values, and the Helm render | — | Read-only |
| `just kube cilium-status` | Print Helm, node, pod, and Cilium status | — | Read-only |
| `just kube cilium-diagnostics` | Print Talos diagnostics from all cluster nodes | — | Read-only |
| `just kube cilium-postflight` | Verify test cleanup, Talos diagnostics, and etcd health | — | Read-only |
| `just kube cilium-verify` | Verify live Cilium, node, Hubble, Talos, and etcd state | `.kube/config` | Operator-only and read-only |
| `just kube cilium-connectivity-test` | Run Cilium's functional IPv4 connectivity suite and remove its temporary workloads | `.kube/config`; `CILIUM_CONNECTIVITY_CONFIRM=test:cilium-connectivity` | Operator-only and state-changing |
| `just bootstrap cilium` | Guard and install or reconcile Cilium `1.19.6` | `CILIUM_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just kube flux-validate` | Validate Flux sources, SOPS canary, dependencies, and Cilium adoption guards | — | Read-only |
| `just kube flux-preflight` | Verify published Git, Cilium/Talos/etcd health, and Kubernetes compatibility | — | Read-only |
| `just bootstrap flux` | Bootstrap Flux `2.9.2` and a read-only GitHub SSH deploy key | `GITHUB_TOKEN`; `FLUX_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just bootstrap flux-sops` | Create or verify the matching in-cluster SOPS identity | `SOPS_AGE_KEY`[`_FILE`]; `FLUX_SOPS_CONFIRM` | Mutating after confirmation |
| `just bootstrap flux-ssh-known-hosts` | Preserve the deploy key and repair GitHub port-443 host trust | `FLUX_SSH_KNOWN_HOSTS_CONFIRM` | Recovery; mutating after confirmation |
| `just bootstrap flux-adopt-cilium` | Adopt Cilium with guarded workload health and stage the permanent unsuspend | `FLUX_CILIUM_ADOPTION_CONFIRM` | Mutating after confirmation |
| `just kube flux-status` | Print Flux controllers and reconciliation state | — | Read-only |
| `just kube flux-verify` | Verify Flux source auth, SOPS, canary, Cilium, Talos, and etcd | — | Read-only |
| `just kube flux-canary-test` | Prove Flux recreates the guarded noncritical canary Secret | `FLUX_CANARY_CONFIRM` | State-changing after confirmation |
| `just kube foundation-validate` | Validate foundation sources, encrypted providers, dependency policy, and pinned chart renders | — | Read-only |
| `just kube foundation-status` | Print certificate, MetalLB, Gateway, ExternalDNS, and echo state | — | Read-only |
| `just bootstrap foundation` | Reconcile the nine staged foundation units in guarded dependency order | `SOPS_AGE_KEY`[`_FILE`]; `FOUNDATION_NETWORK_CONFIRM`; `FOUNDATION_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just kube foundation-verify` | Verify DNS, trusted HTTPS, echo, Cilium, Talos, and etcd acceptance | — | Read-only |
| `just bootstrap reboot <node>` | Gate on cluster health, reboot one node, and require full recovery (TPM auto-unlock, etcd, MetalLB failover, Cilium, DNS, HTTPS) | `TALOS_REBOOT_CONFIRM` | Disruptive after confirmation |
| `just kube flux-restart` | Restart the flux-system controllers and prove reconciliation resumes | `FLUX_RESTART_CONFIRM` | Mutating after confirmation |
| `just repo storage-secrets` | Validate the UNAS CIFS credentials and write only the encrypted Longhorn backup Secret | `SOPS_AGE_KEY`[`_FILE`]; `CIFS_USERNAME`; `CIFS_PASSWORD`; `STORAGE_SECRETS_CONFIRM` | Mutating tracked ciphertext after confirmation |
| `just kube storage-validate` | Validate the Longhorn source, encrypted CIFS Secret, backup-target CR, dependencies, and pinned chart render | — | Read-only |
| `just bootstrap storage` | Reconcile the staged Longhorn Kustomizations in dependency order and run the acceptance gate | `STORAGE_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just kube storage-verify` | Verify Longhorn health, node disks, default StorageClass, backup target, and recurring jobs | `.kube/config` | Operator-only and read-only |
| `just kube storage-provisioning-test` | Create a run-scoped Longhorn PVC and prove two-node replica placement before cleanup | `.kube/config`; `STORAGE_PROVISIONING_CONFIRM=test:storage-provisioning` | Operator-only and state-changing |
| `just repo homepage-tautulli-secrets` | Write only the encrypted Tautulli API key used by the Homepage widget | `SOPS_AGE_KEY`[`_FILE`]; `TAUTULLI_API_KEY`; `HOMEPAGE_TAUTULLI_SECRETS_CONFIRM=write:monitoring:homepage-tautulli:sops` | Tautulli activation; operator-only tracked ciphertext write |
| `just kube tautulli-validate` | Validate suspended/active Tautulli source, storage, probes, route, integrations, and pinned render | — | Cluster-independent; included in `just ci` |
| `just kube alerts-validate <domain>` | Validate one domain alerts application's placement and wiring, then run promtool syntax/unit tests | — | Cluster-independent; included in `just ci` |
| `just kube alerts-coverage-validate` | Require every alert name in the tree to be asserted in a promtool fixture | — | Cluster-independent; included in `just ci` |
| `just bootstrap media-app tautulli` | Guardedly resume staged Tautulli and run liveness acceptance | `MEDIA_APP_BOOTSTRAP_CONFIRM=bootstrap:media-app:tautulli` | Operator-only; mutating after confirmation |
| `just kube tautulli-verify` | Verify live Tautulli resources, route, DNS, exact health status, Gatus series, and loaded rules | `.kube/config` | Operator-only and read-only |
| `just repo portainer-secrets` | Write only the encrypted initial Portainer administrator Secret | `SOPS_AGE_KEY`[`_FILE`]; `PORTAINER_ADMIN_PASSWORD`; `PORTAINER_SECRETS_CONFIRM` | Mutating tracked ciphertext after confirmation |
| `just repo homepage-portainer-secrets` | Write the encrypted Portainer API key used by Homepage and stamp its rollout revision | `SOPS_AGE_KEY`[`_FILE`]; `PORTAINER_API_KEY`; `HOMEPAGE_PORTAINER_SECRETS_CONFIRM` | Operator-held secret workflow; mutates tracked ciphertext and the Homepage Deployment after confirmation |
| `just kube portainer-validate` | Validate the staged Portainer source, chart render, route, storage, isolation, and RBAC | — | Read-only and included in `just ci` |
| `just kube portainer-policy-validate` | Enforce the Portainer read-only RBAC policy with Conftest | — | Read-only and included in `just ci` |
| `just bootstrap portainer` | Guardedly resume the staged Portainer Kustomization and run live acceptance | `PORTAINER_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just kube portainer-verify` | Verify live Portainer, internal HTTPS, storage, policy, and effective authorization | Worktree-local scoped credentials | Approved read-oriented scoped verification |
| `just kube portainer-persistence-test` | Recreate the Portainer pod and prove the original PVC and UI recover | `PORTAINER_PERSISTENCE_CONFIRM` | Operator-only and disruptive after confirmation |
| `just test smoke platform portainer` | Run read-only Portainer deployed-state assertions | `.kube/config` | Operator-only |
| `just ci` | Run the cluster-independent, secret-free validation gate and write one canonical fail-fast JUnit/JSON result | — | Manual local check + authoritative GitHub PR gate; Actions retains the artifact for 90 days |
| `just test validate` | Validate the suite catalog and canonical artifact contract; lint Chainsaw configuration/tests, enforce read-only smoke policy, parse test YAML, and check test scripts | — | Cluster-independent; included in `just ci` |
| `just test catalog-validate` | Validate suite metadata, implementations, dispatch uniqueness, and mutation guards | — | Cluster-independent; included in `just test validate` |
| `just test result-validate <run-id>` | Validate one finalized canonical run, including JUnit/summary consistency, evidence size/path safety, and its complete evidence index | `.test-results/<run-id>` | Cluster-independent; coordinated runners invoke it automatically |
| `just test report <run-id>` | Validate a canonical run and generate its static Allure Awesome report | `.test-results/<run-id>` | Writes `.test-reports/<run-id>/awesome/` |
| `just test report-latest` | Generate the report with the latest finalized `summary.json` end time | `.test-results/` | Does not use filesystem modification time |
| `just test report-open <run-id>` | Generate, serve, and open one Allure report locally | `.test-results/<run-id>`; interactive browser | Runs until interrupted with Ctrl+C |
| `just test campaign-plan <name>` | Preview explicit campaign membership, source authority, mutation scope, and the exact confirmation | Clean deployed `origin/main`; `.kube/config` | Operator-only and read-only |
| `just test campaign <name>` | Run an ordered catalog campaign and automatically publish every canonical child report | `TEST_CAMPAIGN_CONFIRM`; `.kube/config` | Operator-only; may be disruptive according to campaign |
| `just test campaign-resume <campaign-run-id>` | Retry failed publication and continue unstarted campaign members without rerunning completed suites | `TEST_CAMPAIGN_CONFIRM=resume-publish:<campaign-run-id>` | Only publication-failed campaigns are resumable |
| `just kube test-reports-validate` | Validate the suspended persistent Caddy report host, RWO/Recreate storage, isolation, metrics, and atomic installer | — | Cluster-independent; included in `just ci` |
| `just bootstrap test-reports` | Guardedly resume the staged report host and run live acceptance | `TEST_REPORTS_BOOTSTRAP_CONFIRM=bootstrap:test-reports` | Operator-only; mutating after confirmation |
| `just test publish <run-id>` | Secret-scan and publish one canonical run plus static Allure report to the retained in-cluster archive | `.kube/config`; `TEST_REPORT_PUBLISH_CONFIRM=publish:test-report:<run-id>` | Operator-only; no upload API |
| `just kube test-reports-verify` | Verify the live report host, PVC, no-RBAC runtime, internal HTTPS, policy, monitoring resources, and catalog | `.kube/config` | Operator-only and read-only |
| `just test smoke cluster` | Run the read-only Flux readiness proof and write evidence under `.test-results/` | `.kube/config` | Operator-only; never in `just ci` |
| `just test smoke cluster diagnostics-self-test` | Deliberately fail a read-only assertion to prove catch/fallback diagnostics and failure preservation | `.kube/config` | Operator-only; expected failure |
| `just test diagnostics cluster` | Collect allowlisted Flux, Pod, and Event diagnostics without Secret bodies | `.kube/config` | Operator-only; read-only |
| `just test integration media-hardlink` | Run the focused media-data hardlink filesystem integration under the renewable cluster-wide test Lease | `.kube/config` | Operator-only; run-owned files only |
| `just test e2e <target>` | Run an allowlisted state-changing functional scenario under the renewable cluster-wide test Lease | `.kube/config` | Fails closed until a target is registered |
| `just test resilience <target>` | Run an allowlisted disruptive recovery scenario under confirmation and the renewable cluster-wide test Lease | `.kube/config`; `CLUSTER_CHAOS_CONFIRM=chaos:<target>` | Fails closed until a target is registered |
| `just repo hooks` | Install the git pre-commit hooks (idempotent) | — | Available |
| `just repo lint` | Run all pre-commit hooks against the tree | — | Available |
| `just repo links-validate` | Reject broken relative Markdown links, absolute/file Markdown targets, and missing bare repository documentation paths | — | Cluster-independent; included in `just ci` |
| `just kube kubeconform` | Validate the built app manifests against Kubernetes + CRD schemas | — | Available; read-only, fetches schemas over HTTPS |
| `just kube foundation-ca-expiry` | Warn if the committed Pi-hole CA is within 30 days of expiry | — | Operational; time-based, kept out of `just ci` |
| `just kube metrics-server-validate` | Validate the metrics-server source, insecure-TLS flag, and pinned render | — | Available; read-only |
| `just bootstrap metrics-server` | Reconcile the staged metrics-server and verify (`kubectl top`, HPA, Homepage widget) | `METRICS_SERVER_BOOTSTRAP_CONFIRM` | Mutating after confirmation |
| `just kube metrics-server-verify` | Verify metrics-server: APIService Available and `kubectl top nodes` returns data | — | Read-only |
| `just repo ntfy-identity <action> <identity>` | Registry-backed ntfy credential lifecycle (`ensure`/`reconcile`/`rotate`/`finalize`) over the canonical Secret; companions `just repo ntfy-subscriber-password` and `just kube ntfy-consumer-sync seerr` — see [the ntfy guide](docs/guides/ntfy-operations.md) | `SOPS_AGE_KEY`[`_FILE`]; `NTFY_IDENTITY_CONFIRM` | Mutating tracked ciphertext after confirmation |

The **Requires from operator** column lists inputs the recipe reads from your
environment and refuses to run without. `SOPS_AGE_KEY`[`_FILE`] means either the
key value or a path to it. `*_CONFIRM` values are the exact confirmation strings
each guarded recipe prints when refused. Secrets and confirmations are never
stored in `.mise.toml`; recipes fail fast when they are absent.

New cluster mutations are added only with their validation, guard, and
documentation boundary. Do not replace a missing workflow with an ad hoc apply.

### Confirmation safety model

A `*_CONFIRM` value is a deliberate second operator act, not a credential or a
replacement for preflight checks. Require one when a recipe crosses a meaningful
shared or durable boundary: live rollouts or deletion, disruption or destruction,
tracked secret/trust writes, shared-state tests, report publication, or exceptional
cleanup. Read-only checks, planning, validation, and run-owned local output do not
require one.

Tokens bind the authorized action to its target; higher-risk operations also bind
fresh context such as a run ID, node/IP, disk serial, source commit, or campaign
digest. This prevents accidental invocation and reuse against a different target.
The test catalog permits either an `exact` token or a narrowly scoped `command`
guard with bounded ownership and cleanup, but never `none` for a mutating test.
Campaign confirmation delegates only the frozen, source-reviewed child sequence;
standalone and target-specific guards remain intact.

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

Do not use `just bootstrap verify` as a routine check after Cilium is installed.
It is the pre-Cilium bootstrap gate and intentionally expects all nodes to
be `NotReady`. Do not use `just bootstrap cilium` as a status command because it
is an installation/reconciliation workflow with a guarded mutation path.

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

## Normal Change Workflow

1. Read the source-adjacent README and current documentation for the subsystem.
2. Run `just repo tools` after pulling a change to `.mise.toml` or `mise.lock`.
3. Load the SOPS identity only when the change requires encrypted material.
4. Edit declarative source files, never generated output.
5. Run the subsystem's generation or validation recipe when it is available.
6. Inspect `git status` and confirm no generated config, decrypted secret,
   kubeconfig, talosconfig, or private key is trackable.
7. Commit on the feature branch, push it, and open a pull request. GitHub's required
   `ci` check supplies the authoritative full validation result.

Do not bypass a disabled recipe with a raw cluster-changing command. Enable and
test the guarded recipe in the subsystem that owns that operation.

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
support bundles, and age private identities must remain outside Git. The private
repository does not weaken this rule.
