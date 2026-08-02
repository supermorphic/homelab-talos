# Spec Review — 2026-08-02-agent-rules-audit

**Verdict:** Not ready — 12 evidence-backed findings, several against the containment contract the rollout decision depends on.

> Recovered from the codex session transcript. `codex exec -o` captured only the final
> assistant message, so findings were reassembled from
> `~/.codex/sessions/2026/08/02/rollout-…-019fc2ef.jsonl`. Content is codex's, unedited;
> only this header and note were added.

## Findings

### F1 — Defect
**Where:** Decision 2, “The replacement,” and Risks and tradeoffs
**Mechanism:** explicit `spec.retryInterval`, bounded Helm remediation, and a `NotReady` alert are said to bound reapplication and replace the cleanup trap that suspends a failed Kustomization
**Failure:** `retryInterval` schedules another failed reconciliation and the alert only notifies; neither stops reconciliation or changes desired state. Helm remediation exhausts retries for a Helm action, but the parent Kustomization continues failed reconciliation, and non-Helm failures have no remediation counter at all. The removed trap halts reconciliation, while the replacement does not.
**When:** a Kustomization remains `NotReady` and the operator does not manually suspend or revert it after the alert

### F2 — Defect
**Where:** Decision 1, “Credential tiers,” “Path strategy,” and “Tier visibility”
**Mechanism:** the main clone stores admin kubeconfig and talosconfig, the admin tier is declared “Operator only,” and a `SessionStart` hook merely warns an agent running there
**Failure:** repository-relative credential files provide no operator/agent isolation. An agent session launched in the main clone can read and use the admin configurations; the spec explicitly says that such a session is legitimate, that the hook never blocks, and that `bypassPermissions` leaves the main clone writable. “Admin credential custody” therefore does not enforce the operator-only boundary claimed for it.
**When:** an agent session runs from the main clone after admin credentials have been created there

### F3 — Defect
**Where:** Status; Decision 4, “Record identity and immutability semantics” and “Index contract”
**Mechanism:** a new record is committed as `Draft`, becomes `Accepted` when merged, and the committed Status header is the index’s source of truth
**Failure:** Git merges the reviewed file content unchanged, so a normal merge leaves both the record and generated index saying `Draft`. No post-merge writer is specified. The next comparison also sees a `Draft` header in the merge base, so the rule that protects an `Accepted` record is not engaged by the state the mechanism actually stored.
**When:** any new decision record passes PR validation as `Draft` and is merged to `main`

### F4 — Defect
**Where:** Decision 3, policy architecture, Resource layer
**Mechanism:** policy over `kustomize build` output is assigned workload-level checks such as dropped capabilities, mutable image tags, `NET_ADMIN`, and RWO-PVC deployment strategy across all apps
**Failure:** for Helm-managed apps the build output contains a `HelmRelease` and values-bearing ConfigMap, not the generated Deployment, Pod, or PVC. A chart can ignore, rename, default, or transform a values key while the resource-layer check still passes, leaving the actual rendered workload in violation. This is exactly the render-effect boundary the spec assigns to a different layer.
**When:** an app is deployed through a `HelmRelease`, including the existing app-template apps such as Sonarr

### F5 — Contradiction
**Where:** Decision 2, “Post-merge acceptance”; Decision 1 division-of-labour table; final `AGENTS.md` rule table
**Post-merge acceptance says:** on verification failure, the activating commit is reverted unless the operator explicitly accepts the failure, after which Flux converges to the prior state
**Division of labour and the rule table say:** only the operator merges, and no merge or auto-merge occurs without authorization for that specific merge
**Why both cannot hold:** Flux can converge to the prior Git state only after the revert reaches `main`. An automatic failure response reaches `main` without the operator authorizing that specific revert merge; a revert PR that waits for operator action does not satisfy the specified automatic response or bound the failed state.

### F6 — Ambiguity
**Where:** Decision 2, “Post-merge acceptance” and its explicit open credential conflict
**Reading 1:** merge-triggered workstation or external automation runs each verifier with a scoped kubeconfig and writes the canonical `.test-results/` directory on that host
**Reading 2:** a Flux-created in-cluster Job runs with its own ServiceAccount and must emit or transport canonical evidence from the cluster into the retained reporting pipeline
**Different implementations:** the first requires an external merge-event runner, credential lifecycle, and host artifact storage; the second requires Kubernetes Job/RBAC resources plus an evidence transport and ingestion path. The spec records the choice as unresolved while sequencing still instructs implementation to build the automation.

### F7 — Defect
**Where:** Decision 4, “Record identity and immutability semantics” and “Link validation: introduce-then-freeze”
**Mechanism:** legal supersession modifies an accepted record’s Status line, while link validation scans every decision record added or modified relative to the merge base
**Failure:** the status-only supersession makes the accepted record “modified,” so all of its links are validated again. If any formerly valid local target has since moved or disappeared, the record cannot be superseded without repairing other content that the immutability rule forbids changing. The result is not frozen at acceptance under the stated diff selector.
**When:** an accepted record with a now-stale local link is superseded

### F8 — Ambiguity
**Where:** Decision 2, containment alert threshold
**Reading 1:** extend the existing single `FluxReconciliationFailure` rule, which has one static Prometheus `for` duration shared by every matching series
**Reading 2:** generate separate alert rules or groups keyed by each Kustomization’s `spec.timeout + spec.retryInterval`
**Different implementations:** the first stores one threshold and cannot implement the per-Kustomization sum; the second adds generated per-object alert configuration and source-to-alert coupling. The current `gotk_resource_info` series exposes readiness and identity but neither duration field, so the spec does not determine which architecture implements its threshold.

### F9 — Contradiction
**Where:** The admission test and Decision 4, final `AGENTS.md` rule table
**The admission test says:** a Gotcha is information backed by nothing, while an Authoritative control is a boundary backed by a mechanism; each rule fits exactly one category
**The final rule table says:** “Cluster-dependent suites never enter `just ci`” is a Gotcha backed by `validation.test-harness`, and the app layout rule is a Gotcha backed by source-layer policy
**Why both cannot hold:** those rows are normative requirements with named mechanisms, which the category definition says are not Gotchas. The proposed final rule set therefore fails its own exactly-one-category admission test.

### F10 — Defect
**Where:** Decision 4, final `AGENTS.md` rule table
**Mechanism:** “Never commit or push directly to `main`” is classified as an Authoritative control backed by branch protection
**Failure:** branch protection rejects an unauthorized server update but cannot prevent a local commit on the checked-out `main` branch. The `SessionStart` hook is specified as warning-only. The combined rule consequently claims authoritative enforcement for an action its named control does not intercept, contrary to the spec’s enforcement-strength test.
**When:** an agent creates a local commit while the main clone has `main` checked out

### F11 — Ambiguity
**Where:** Decision 2, one-PR eligibility criterion 2
**Reading 1:** any Gatus reachability or health endpoint qualifies as “functional monitoring,” so an HTTP/TCP success check can make an app eligible
**Reading 2:** the endpoint must exercise the app-specific function that the removed verifier or gate covered, such as GPU scheduling, SMB mounting, or alert delivery
**Different implementations:** the first adds shallow endpoints and deletes more bootstrap recipes; the second requires functional transactions that several named apps cannot express as a service endpoint and therefore retains their recipes. The criterion decides rollout authority but never defines which evidence qualifies.

### F12 — Defect
**Where:** Decision 1, credential source table, path strategy, on-demand minting, and Appendix B
**Mechanism:** worktrees are to receive a 90-day `os:reader` talosconfig on demand, but the only on-demand recipe specified is conditional `just talos kubeconfig`, which writes the scoped Kubernetes kubeconfig
**Failure:** the worktree remains without `.talos/config`, exactly as Appendix B says it starts. Talos-backed read-only diagnostics therefore fail for lack of a talosconfig even after the operator performs the documented minting command; the stated `os:reader` tier has a source command but no path in the on-demand workflow that installs it at the repository-relative location.
**When:** an agent in a worktree needs a retained Talos diagnostic such as `just kube cilium-diagnostics`

## Grounding

- **Assumption:** retry controls replace suspension. **Checked:** `.just/bootstrap.just` cleanup functions and the official Flux Kustomization and HelmRelease behavior. **Found:** the current trap calls `flux suspend`; Flux documents `retryInterval` as the interval for another failed reconciliation, while finite Helm remediation stops Helm action retries after exhaustion but does not suspend the parent Kustomization.
- **Assumption:** admin credentials are operator-only in the main clone. **Checked:** current credential paths in `.just/bootstrap.just`, `talos/mod.just`, `.just/repository.just`, plus the spec’s own `bypassPermissions` and warning-only statements. **Found:** both configs are ordinary repository-relative files and no process or filesystem boundary distinguishes an operator from an agent launched in that clone.
- **Assumption:** merge changes a committed Status header. **Checked:** `.github/workflows/ci.yml` and repository searches for decision/status automation. **Found:** the only workflow is PR/manual, has `contents: read`, and no existing or proposed post-merge status writer is specified.
- **Assumption:** `kustomize build` exposes rendered Helm workloads. **Checked:** `mise exec -- kustomize build kubernetes/apps/media/sonarr/app`. **Found:** output contains ConfigMap, HTTPRoute, and HelmRelease objects; it contains no generated Deployment, Pod, or PVC.
- **Assumption:** automation can revert production without crossing the merge boundary. **Checked:** `scripts/repository/github_protection.py` and `.github/workflows/ci.yml`. **Found:** the tracked ruleset requires pull requests and the existing automation has read-only contents permission; no bypass actor or write-capable merge path exists.
- **Assumption:** the current reporting pipeline supplies an in-cluster acceptance artifact path. **Checked:** `tests/README.md`, `.github/workflows/ci.yml`, and `scripts/test/publish-report.sh`. **Found:** canonical results are created on a workstation/CI filesystem, CI uploads them as workflow artifacts, and persistent publication is a separate operator-confirmed stream into the cluster; there is no reverse in-cluster ingestion path.
- **Assumption:** introduce-then-freeze skips a superseded accepted record. **Checked:** the proposed diff rule and current `scripts/validate/links.sh`. **Found:** the current validator checks local Markdown targets, and the proposal selects every modified decision file without an exception for a status-only supersession.
- **Assumption:** the existing metric can express a dynamic per-Kustomization threshold. **Checked:** `kubernetes/apps/monitoring/flux-kube-state-metrics/app/values.yaml`, `kubernetes/apps/monitoring/kube-prometheus-stack/config/flux-alerts.yaml`, and its Prometheus tests. **Found:** the series carries kind, namespace, name, readiness, and suspension labels only; the alert uses one static `for: 15m`.
- **Assumption:** final rule categories satisfy the admission taxonomy. **Checked:** every Gotcha row in the final rule table against the category definitions. **Found:** at least two Gotcha rows name enforcing validators, although Gotcha is defined as having no backing control.
- **Assumption:** branch protection blocks local commits. **Checked:** the tracked GitHub ruleset in `scripts/repository/github_protection.py`. **Found:** it governs updates to `refs/heads/main` on GitHub and has no local-commit mechanism.
- **Assumption:** current Gatus checks establish one consistent meaning of functional monitoring. **Checked:** `kubernetes/apps/monitoring/gatus/app/values.yaml` and the named uncovered apps. **Found:** existing checks range from UI reachability to specific health APIs, while several uncovered components expose no equivalent application endpoint; the repository does not supply a common qualifying contract.
- **Assumption:** the on-demand flow installs the Talos reader credential. **Checked:** `talos/mod.just`, `kubernetes/mod.just`, Appendix B, and the official Talos PKI command behavior. **Found:** `just talos kubeconfig` currently writes only `.kube/config`; Talos read diagnostics consume `.talos/config`; and `talosctl config new` can mint `os:reader` only when invoked against a control-plane node with admin authority, but that invocation is absent from the documented on-demand flow.
*** End Patch",
  "tool": "apply_patch"
}
>>> APPROVAL REQUEST END
