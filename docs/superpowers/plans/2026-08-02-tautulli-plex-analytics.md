# Tautulli Plex Analytics and Media Alerting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Tautulli as an authenticated, durable Plex analytics service and add tested media availability and persistence alerts without coupling media applications to the Prometheus Operator.

**Architecture:** Tautulli is a config-only `app-template` workload in the `media` namespace: one `Recreate` Deployment, one retained Longhorn RWO PVC at `/config`, an internal Gateway API route, and no shared media or Plex volume. A separate unsuspended `media-alerts` Flux Kustomization depends on `kube-prometheus-stack` and owns all new media `PrometheusRule` objects. Delivery uses a suspended application PR, an operator-run authentication/playback gate, and an activation PR that adds the API-key-dependent Homepage widget, Gatus endpoint, Tautulli-specific absence alerts, and live Prometheus verification.

**Tech Stack:** Flux Kustomizations and HelmReleases, bjw-s `app-template` 5.0.1, Kubernetes Gateway API, Longhorn, Bash 5, `yq`, `kustomize`, `helm`, `promtool` 3.13.1, Conftest/Rego, SOPS/age, Homepage, Gatus, Prometheus Operator, `just`, and the repository's pinned `mise` toolchain.

## Global Constraints

- Work only on branch `tautulli-monitoring-addition`; never commit, push, merge, or enable auto-merge on `main`.
- Preserve unrelated user changes. Immediately before each push, require a clean branch, run `mise exec -- git fetch origin`, and safely rebase onto `origin/main` when needed.
- Run repository workflows through `mise exec -- just ...`; use `mise exec -- <tool> ...` only for pinned ad hoc inspection when no recipe exists.
- Use guarded `just` recipes for every live-cluster check or mutation. The operator, not an implementation agent, runs the mutating bootstrap and SOPS Secret recipes.
- Deliver exactly two PRs with the operator gate in this plan between them. PR 1 stages Tautulli with `spec.suspend: true`; PR 2 persists `spec.suspend: false` only after every acceptance gate passes.
- Pin `ghcr.io/home-operations/tautulli:2.17.2`; do not substitute another tag without superseding `docs/decisions/2026-08-01-tautulli.md`.
- Tautulli runs in namespace `media`, listens on `8181`, and is routed only at `tautulli.lab.supermorphic.com` through the `internal` Gateway.
- Tautulli depends on `internal-gateway` and `media`, not `media-storage` or `plex`.
- Use one Deployment with `strategy: Recreate` because the SQLite config PVC is `ReadWriteOnce`.
- The config PVC is `5Gi`, class `longhorn`, `ReadWriteOnce`, retained with `helm.sh/resource-policy: keep`, and mounted at `/config`. Never add `persistence.data`, `persistence.media`, the Plex PVC, or any shared media claim.
- Run as UID/GID/fsGroup `568`, set `fsGroupChangePolicy: OnRootMismatch`, disable privilege escalation, and drop `ALL` capabilities.
- Request `25m` CPU and `256Mi` memory, limit memory to `1Gi`, and set no CPU limit.
- Initially use custom HTTP probes on `/status`: readiness `periodSeconds: 10`, `failureThreshold: 3`; liveness `30` and `5`; startup `5` and `30`.
- Treat an exact unauthenticated and authenticated `/status` response code of `200` as a blocking gate. Kubernetes probe success on a 3xx is not acceptance.
- Web authentication is mandatory before activation. Record the tested auth mode and exact authenticated `/status` result in PR 2.
- PR 1 contains no Tautulli Gatus endpoint, no `widget.*` annotations, no Homepage Tautulli Secret/env/resource, and no `TautulliProbeMissing` or `TautulliPersistentVolumeClaimNotBound` rule.
- `media-alerts` is unsuspended in PR 1 and depends only on `kube-prometheus-stack`; do not put a new `PrometheusRule` under another media application's `app/` directory.
- `qbittorrent/app/prometheusrule.yaml` is the single named legacy exception to the media-alert placement policy. Do not widen the exception or change qBittorrent in this work.
- `MediaEndpointDown` excludes `qbittorrent-vpn`, uses `for: 15m`, and labels alerts `severity: warning`; `QbittorrentVpnDown` already owns that endpoint at `critical`.
- Plex PVC loss is `critical`; Tautulli PVC loss and all Gatus availability/missing-series alerts are `warning`.
- Never decrypt, rewrite by hand, inspect plaintext from, or copy ciphertext into `homepage-tautulli.sops.yaml`. The operator creates it only through the guarded recipe in Task 10.
- Do not add ntfy integration, a Prometheus exporter, newsletters, history import, Plex Logs mounting, Chainsaw coverage, resilience coverage, E2E automation, or qBittorrent alert refactoring.
- New documentation must not use rollout `Phase N` wording. On any existing line edited by this work, remove such wording.
- The `bootstrap media-app` recipe is intentionally temporary: accepted decision D15 expects the separate agent-rules-audit workstream to delete it later. Do not pre-implement that other branch here.

## Delivery Boundaries and File Map

PR 1 owns the suspended application, generic/Plex media alerts, offline validation, policy contract, guarded rollout, Secret-generation recipe, liveness verifier, catalog registration, and operator instructions:

- Create `kubernetes/apps/media/tautulli/ks.yaml` — suspended Flux child with `media` and `internal-gateway` dependencies.
- Create `kubernetes/apps/media/tautulli/app/helmrelease.yaml` — `app-template` HelmRelease.
- Create `kubernetes/apps/media/tautulli/app/values.yaml` — workload, probes, security, resources, Service, and retained config PVC.
- Create `kubernetes/apps/media/tautulli/app/httproute.yaml` — internal route and non-widget Homepage discovery metadata.
- Create `kubernetes/apps/media/tautulli/app/kustomization.yaml` — app resources and generated values ConfigMap.
- Create `kubernetes/apps/media/alerts/ks.yaml` — unsuspended, CRD-gated Flux child.
- Create `kubernetes/apps/media/alerts/app/kustomization.yaml` — alert resource list.
- Create `kubernetes/apps/media/alerts/app/prometheusrule.yaml` — PR 1's four generic/Plex rules.
- Create `scripts/validate/tautulli.sh` — complete activation-aware application contract.
- Create `scripts/validate/media-alerts.sh` — placement checks plus single-sourced promtool validation.
- Create `scripts/verify/tautulli.sh` — live resource, route, DNS, and exact `/status` checks.
- Create `tests/prometheus/media-alerts_test.yaml` — temporal and matcher tests for the PR 1 rules.
- Modify `kubernetes/apps/media/kustomization.yaml` — register `alerts` and `tautulli`.
- Modify `tests/policy/media/media.rego` and `tests/policy/media/media_test.rego` — dependencies and config-only contract.
- Modify `kubernetes/mod.just` and `tests/catalog.yaml` — two validations and one verification.
- Modify `.just/bootstrap.just` — guarded `media-app tautulli` rollout.
- Modify `.just/repository.just` — Homepage Secret recipe and rollout-guard count `24` → `25`.
- Modify `docs/arr-stack-startup.md` — rollout, setup, authentication, playback, API key, and Plex Logs limitation.
- Modify `README.md` — new operator-facing recipes.

PR 2 owns activation and only the integrations whose inputs or correctness depend on the running application:

- Modify `kubernetes/apps/media/tautulli/ks.yaml` — persist `suspend: false`.
- Modify `kubernetes/apps/media/tautulli/app/httproute.yaml` — add the three `widget.*` annotations.
- Modify `kubernetes/apps/media/alerts/app/prometheusrule.yaml` — add both Tautulli absence rules.
- Modify `tests/prometheus/media-alerts_test.yaml` — add temporal/matcher cases for both rules.
- Modify `kubernetes/apps/monitoring/gatus/app/values.yaml` — add the Tautulli endpoint.
- Create `kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml` — operator-generated ciphertext only.
- Modify `kubernetes/apps/monitoring/homepage/app/deployment.yaml` — optional API-key environment variable.
- Modify `kubernetes/apps/monitoring/homepage/app/kustomization.yaml` — reconcile the encrypted Secret.
- Modify `scripts/verify/tautulli.sh` — verify the live Gatus series and all six loaded rules.
- Modify `docs/arr-stack-startup.md` — record the observed auth mode and authenticated status result.

If authenticated `/status` is not exactly `200`, stop after Task 8. The accepted design permits a TCP-probe/login-page fallback, but the login URL is live evidence rather than a value in the spec. Record the returned status and `Location` header, amend this plan with that literal path and the exact `values.yaml`/Gatus changes, then review the amendment before starting PR 2. Do not guess the path and do not activate with green-but-redirecting probes.

---

## PR 1 — Suspended Application and Existing-Media Alerting

### Task 1: Rebase and Add the Tautulli Media Policy Contract

**Files:**
- Modify: `tests/policy/media/media.rego:7-40`
- Modify: `tests/policy/media/media_test.rego:82-113,460-480`

**Interfaces:**
- Consumes: The media-policy input document convention (`path`, `contents`) and existing `deny` rules.
- Produces: `required_dependencies["tautulli"] == {"internal-gateway", "media"}` and membership in `config_only_apps`.

- [ ] **Step 1: Confirm branch and production baseline**

Run:

```bash
mise exec -- git status --short --branch
mise exec -- git fetch origin
mise exec -- git rebase origin/main
mise exec -- just kube media-policy-validate
```

Expected: branch `tautulli-monitoring-addition`, a clean rebase, and the existing media policy suite passes. If unrelated changes are present, stop and preserve them.

- [ ] **Step 2: Write the failing Tautulli fixture and contract tests**

Add this fixture beside `config_only_fixture`:

```rego
tautulli_fixture(dependencies, extra_persistence) := [
	{
		"path": "kubernetes/apps/media/tautulli/app/values.yaml",
		"contents": {
			"controllers": {"tautulli": {
				"strategy": "Recreate",
				"containers": {"app": {
					"image": {"tag": "2.17.2"},
					"securityContext": {"capabilities": {"drop": ["ALL"]}},
				}},
			}},
			"persistence": object.union(
				{"config": {"accessMode": "ReadWriteOnce"}},
				extra_persistence,
			),
		},
	},
	{
		"path": "kubernetes/apps/media/tautulli/ks.yaml",
		"contents": {"spec": {"dependsOn": [{"name": dependency} | some dependency in dependencies]}},
	},
	{
		"path": "kubernetes/apps/media/tautulli/app/httproute.yaml",
		"contents": {
			"metadata": {"annotations": {"external-dns.k8s.io/audience": "internal"}},
			"spec": {"parentRefs": [{"name": "internal"}]},
		},
	},
]
```

Add these tests near the Lidarr contract tests:

```rego
test_valid_tautulli_contract_has_no_violations if {
	messages := deny with input as tautulli_fixture({"internal-gateway", "media"}, {})
	count(messages) == 0
}

test_tautulli_requires_internal_gateway_dependency if {
	messages := deny with input as tautulli_fixture({"media"}, {})
	count(messages_matching(messages, "required Flux dependency \"internal-gateway\"")) == 1
}

test_tautulli_requires_media_dependency if {
	messages := deny with input as tautulli_fixture({"internal-gateway"}, {})
	count(messages_matching(messages, "required Flux dependency \"media\"")) == 1
}

test_tautulli_must_not_define_data if {
	messages := deny with input as tautulli_fixture(
		{"internal-gateway", "media"},
		{"data": {"existingClaim": "media-data"}},
	)
	count(messages_matching(messages, "tautulli is config-only and must not define persistence.data")) == 1
}

test_tautulli_must_not_define_media if {
	messages := deny with input as tautulli_fixture(
		{"internal-gateway", "media"},
		{"media": {"existingClaim": "media-data"}},
	)
	count(messages_matching(messages, "tautulli is config-only and must not define persistence.media")) == 1
}
```

- [ ] **Step 3: Run the policy suite and verify the new contract fails**

Run:

```bash
mise exec -- just kube media-policy-validate
```

Expected: FAIL because Tautulli is undefined in `required_dependencies` and is not yet config-only.

- [ ] **Step 4: Add the minimal policy entries**

Replace the dependency map and config-only set with the exact current map plus Tautulli:

```rego
required_dependencies := {
	"flaresolverr": {"media"},
	"lidarr": {"internal-gateway", "media-storage"},
	"plex": {"internal-gateway", "media-storage"},
	"prowlarr": {"internal-gateway", "media"},
	"qbit-manage": {"media-storage", "qbittorrent"},
	"qbittorrent": {"internal-gateway", "media-storage"},
	"radarr": {"internal-gateway", "media-storage"},
	"seerr": {"internal-gateway", "media"},
	"sonarr": {"internal-gateway", "media-storage"},
	"tautulli": {"internal-gateway", "media"},
}

config_only_apps := {"prowlarr", "seerr", "tautulli"}
```

- [ ] **Step 5: Run the focused policy suite**

Run:

```bash
mise exec -- just kube media-policy-validate
```

Expected: PASS, including the valid contract and both shared-claim denials.

- [ ] **Step 6: Commit the policy contract**

```bash
mise exec -- git add tests/policy/media/media.rego tests/policy/media/media_test.rego
mise exec -- git commit -m "test(policy): enforce tautulli media contract"
```

### Task 2: Add the Suspended Tautulli Flux Application and Offline Validator

**Files:**
- Create: `kubernetes/apps/media/tautulli/ks.yaml`
- Create: `kubernetes/apps/media/tautulli/app/helmrelease.yaml`
- Create: `kubernetes/apps/media/tautulli/app/values.yaml`
- Create: `kubernetes/apps/media/tautulli/app/httproute.yaml`
- Create: `kubernetes/apps/media/tautulli/app/kustomization.yaml`
- Create: `scripts/validate/tautulli.sh`
- Modify: `kubernetes/apps/media/kustomization.yaml:14-15`
- Modify: `kubernetes/mod.just:563-572`
- Modify: `tests/catalog.yaml:26,258-261`

**Interfaces:**
- Consumes: Shared OCIRepository `app-template`, namespace Flux child `media`, internal Gateway `internal`, and the policy contract from Task 1.
- Produces: Flux Kustomization/HelmRelease/Deployment/Service/HTTPRoute `tautulli`, PVC `media/tautulli`, validation catalog ID `validation.tautulli`, and recipe `just kube tautulli-validate`.

- [ ] **Step 1: Register a validator that fails on missing source**

Create `scripts/validate/tautulli.sh` with executable mode and these exact contracts:

```bash
#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/tautulli'
ks="$base/ks.yaml"
hr="$base/app/helmrelease.yaml"
values="$base/app/values.yaml"
route="$base/app/httproute.yaml"
app_kustomization="$base/app/kustomization.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
homepage_deployment='kubernetes/apps/monitoring/homepage/app/deployment.yaml'
homepage_kustomization='kubernetes/apps/monitoring/homepage/app/kustomization.yaml'
homepage_secret='kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-tautulli-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$route" "$app_kustomization" "$oci" \
  "$gatus_values" "$homepage_deployment" "$homepage_kustomization"; do
  [[ -f "$f" ]] || { echo "Missing Tautulli source: $f" >&2; exit 1; }
done
rg -qx '  - ./tautulli/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./tautulli/ks.yaml is not wired into the media kustomization.' >&2
  exit 1
}

suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
[[ "$(yq -r '.spec.decryption // "none"' "$ks")" == 'none' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'internal-gateway,media' ]]
[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

[[ "$(yq -r '.controllers.tautulli.strategy' "$values")" == 'Recreate' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.image.repository' "$values")" == 'ghcr.io/home-operations/tautulli' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.image.tag' "$values")" == '2.17.2' ]]
[[ "$(yq -r '.controllers.tautulli.pod.securityContext.runAsUser' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.tautulli.pod.securityContext.runAsGroup' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.tautulli.pod.securityContext.fsGroup' "$values")" == '568' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.securityContext.allowPrivilegeEscalation' "$values")" == 'false' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.securityContext.capabilities.drop | join(",")' "$values")" == 'ALL' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.requests.cpu' "$values")" == '25m' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.requests.memory' "$values")" == '256Mi' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.limits.memory' "$values")" == '1Gi' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.resources.limits.cpu // "none"' "$values")" == 'none' ]]

for probe in readiness liveness startup; do
  [[ "$(yq -r ".controllers.tautulli.containers.app.probes.$probe.custom" "$values")" == 'true' ]]
  [[ "$(yq -r ".controllers.tautulli.containers.app.probes.$probe.spec.httpGet.path" "$values")" == '/status' ]]
  [[ "$(yq -r ".controllers.tautulli.containers.app.probes.$probe.spec.httpGet.port" "$values")" == '8181' ]]
done
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.readiness.spec.periodSeconds' "$values")" == '10' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.readiness.spec.failureThreshold' "$values")" == '3' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.liveness.spec.periodSeconds' "$values")" == '30' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.liveness.spec.failureThreshold' "$values")" == '5' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.startup.spec.periodSeconds' "$values")" == '5' ]]
[[ "$(yq -r '.controllers.tautulli.containers.app.probes.startup.spec.failureThreshold' "$values")" == '30' ]]

[[ "$(yq -r '.service.app.ports.http.port' "$values")" == '8181' ]]
[[ "$(yq -r '.persistence.config.accessMode' "$values")" == 'ReadWriteOnce' ]]
[[ "$(yq -r '.persistence.config.size' "$values")" == '5Gi' ]]
[[ "$(yq -r '.persistence.config.storageClass' "$values")" == 'longhorn' ]]
[[ "$(yq -r '.persistence.config.annotations."helm.sh/resource-policy"' "$values")" == 'keep' ]]
[[ "$(yq -r '.persistence.config.globalMounts[0].path' "$values")" == '/config' ]]
[[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]]
[[ "$(yq -r '.persistence.media // "none"' "$values")" == 'none' ]]

[[ "$(yq -r '.spec.hostnames[0]' "$route")" == 'tautulli.lab.supermorphic.com' ]]
[[ "$(yq -r '.spec.parentRefs[0].name' "$route")" == 'internal' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].name' "$route")" == 'tautulli' ]]
[[ "$(yq -r '.spec.rules[0].backendRefs[0].port' "$route")" == '8181' ]]
widget_count="$(yq -r '[(.metadata.annotations // {}) | keys[] | select(startswith("gethomepage.dev/widget."))] | length' "$route")"
gatus_count="$(yq -r '[.config.endpoints[] | select(.name == "tautulli" and .group == "Media")] | length' "$gatus_values")"
homepage_env_count="$(yq -r '[.spec.template.spec.containers[].env[]? | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY")] | length' "$homepage_deployment")"
homepage_resource_count="$(yq -r '[.resources[] | select(. == "./homepage-tautulli.sops.yaml")] | length' "$homepage_kustomization")"
if [[ "$suspend_state" == 'true' ]]; then
  [[ "$widget_count" == '0' ]]
  [[ "$gatus_count" == '0' ]]
  [[ "$homepage_env_count" == '0' ]]
  [[ "$homepage_resource_count" == '0' ]]
  [[ ! -e "$homepage_secret" ]]
else
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.type"' "$route")" == 'tautulli' ]]
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.url"' "$route")" == 'http://tautulli.media.svc.cluster.local:8181' ]]
  [[ "$(yq -r '.metadata.annotations."gethomepage.dev/widget.key"' "$route")" == '{{HOMEPAGE_VAR_TAUTULLI_API_KEY}}' ]]
  [[ "$gatus_count" == '1' ]]
  [[ "$(yq -r '.config.endpoints[] | select(.name == "tautulli") | .url' "$gatus_values")" == 'https://tautulli.lab.supermorphic.com/status' ]]
  [[ "$(yq -r '.config.endpoints[] | select(.name == "tautulli") | .conditions | join(",")' "$gatus_values")" == '[STATUS] == 200' ]]
  [[ "$homepage_env_count" == '1' ]]
  [[ "$homepage_resource_count" == '1' ]]
  [[ -f "$homepage_secret" ]]
  [[ "$(sops filestatus "$homepage_secret" | yq -r '.encrypted')" == 'true' ]]
  [[ "$(yq -r '.metadata.name' "$homepage_secret")" == 'homepage-tautulli' ]]
  [[ "$(yq -r '.metadata.namespace' "$homepage_secret")" == 'homepage' ]]
  [[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY") | .valueFrom.secretKeyRef.name] | .[0]' "$homepage_deployment")" == 'homepage-tautulli' ]]
  [[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY") | .valueFrom.secretKeyRef.key] | .[0]' "$homepage_deployment")" == 'apiKey' ]]
  [[ "$(yq -r '[.spec.template.spec.containers[].env[] | select(.name == "HOMEPAGE_VAR_TAUTULLI_API_KEY") | .valueFrom.secretKeyRef.optional] | .[0]' "$homepage_deployment")" == 'true' ]]
fi

chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template tautulli "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'tautulli' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]
[[ "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$temp_dir/render.yaml")" == 'tautulli' ]]

echo 'Tautulli source, config-only storage, security, probes, route, activation boundary, and pinned render passed validation.'
```

Add this recipe to `kubernetes/mod.just`:

```just
# Validate the Tautulli source, config-only retained PVC, security/resources, exact probes,
# internal route, activation-aware Gatus/Homepage boundary, and pinned app-template render.
# Cluster-independent and included in `just ci`.
tautulli-validate: require-bash
    @scripts/validate/tautulli.sh
```

Register `validation.tautulli` beside `validation.seerr` and add it to `executions.ci`:

```yaml
  - metadata: {id: validation.tautulli, source: validation, framework: bash, suite: ci, tier: offline, target: tautulli, scenario: source, scope: application, intent: regression, mutates_cluster: false, execution_owner: shared}
    confirmation: {type: none, variable: null, expected: null}
    runner: {command: "mise exec -- just kube tautulli-validate", implementation: scripts/validate/tautulli.sh}
    native_results: {strategy: wrapper-junit}
```

- [ ] **Step 2: Run the validator and prove the source is absent**

Run:

```bash
mise exec -- just kube tautulli-validate
```

Expected: FAIL with `Missing Tautulli source: kubernetes/apps/media/tautulli/ks.yaml`.

- [ ] **Step 3: Create the suspended Flux and Helm resources**

Create `kubernetes/apps/media/tautulli/ks.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: tautulli
  namespace: flux-system
spec:
  dependsOn:
    - name: media
    - name: internal-gateway
  interval: 1h
  path: ./kubernetes/apps/media/tautulli/app
  prune: true
  retryInterval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  suspend: true
  timeout: 10m
  wait: true
```

Create `kubernetes/apps/media/tautulli/app/helmrelease.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: tautulli
  namespace: media
spec:
  chartRef:
    kind: OCIRepository
    name: app-template
  driftDetection:
    mode: enabled
  install:
    remediation:
      retries: 3
  interval: 1h
  releaseName: tautulli
  timeout: 10m
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
      strategy: rollback
  valuesFrom:
    - kind: ConfigMap
      name: tautulli-values
      valuesKey: values.yaml
```

Create `kubernetes/apps/media/tautulli/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./httproute.yaml
configMapGenerator:
  - name: tautulli-values
    namespace: media
    files:
      - values.yaml=values.yaml
generatorOptions:
  disableNameSuffixHash: true
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

- [ ] **Step 4: Create the exact workload values**

Create `kubernetes/apps/media/tautulli/app/values.yaml`:

```yaml
# Tautulli provides Plex analytics and watch history over the Plex API. It is config-only:
# the retained /config PVC holds SQLite state, and no Plex or shared-media claim is mounted.
# Plex Logs is therefore intentionally unavailable. UID 568 write access is confirmed at rollout.
controllers:
  tautulli:
    type: deployment
    strategy: Recreate
    pod:
      securityContext:
        runAsUser: 568
        runAsGroup: 568
        fsGroup: 568
        fsGroupChangePolicy: OnRootMismatch
    containers:
      app:
        image:
          repository: ghcr.io/home-operations/tautulli
          tag: 2.17.2
        env:
          TZ: America/Denver
        resources:
          requests:
            cpu: 25m
            memory: 256Mi
          limits:
            memory: 1Gi
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
        probes:
          readiness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /status
                port: 8181
              periodSeconds: 10
              failureThreshold: 3
          liveness:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /status
                port: 8181
              periodSeconds: 30
              failureThreshold: 5
          startup:
            enabled: true
            custom: true
            spec:
              httpGet:
                path: /status
                port: 8181
              periodSeconds: 5
              failureThreshold: 30
service:
  app:
    controller: tautulli
    ports:
      http:
        port: 8181
persistence:
  config:
    type: persistentVolumeClaim
    accessMode: ReadWriteOnce
    size: 5Gi
    storageClass: longhorn
    annotations:
      helm.sh/resource-policy: keep
    globalMounts:
      - path: /config
```

- [ ] **Step 5: Create the internal route without widget annotations**

Create `kubernetes/apps/media/tautulli/app/httproute.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tautulli
  namespace: media
  annotations:
    external-dns.k8s.io/audience: internal
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: "Tautulli"
    gethomepage.dev/description: "Plex analytics"
    gethomepage.dev/pod-selector: "app.kubernetes.io/name=tautulli"
    gethomepage.dev/group: "Media"
    gethomepage.dev/icon: "tautulli.svg"
    gethomepage.dev/href: "https://tautulli.lab.supermorphic.com"
spec:
  hostnames:
    - tautulli.lab.supermorphic.com
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internal
      namespace: networking
      sectionName: https
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: tautulli
          port: 8181
          weight: 1
      matches:
        - path:
            type: PathPrefix
            value: /
```

- [ ] **Step 6: Wire the application into the media root**

Add this resource beside `seerr` and keep the existing ordering stable:

```yaml
  - ./tautulli/ks.yaml
```

- [ ] **Step 7: Run focused validation and policy checks**

Run:

```bash
mise exec -- just kube tautulli-validate
mise exec -- just kube media-policy-validate
mise exec -- just kube kubeconform
```

Expected: all three pass; the render contains Deployment `tautulli`, strategy `Recreate`, and PVC `tautulli`.

- [ ] **Step 8: Commit the suspended app**

```bash
mise exec -- git add kubernetes/apps/media/tautulli kubernetes/apps/media/kustomization.yaml scripts/validate/tautulli.sh kubernetes/mod.just tests/catalog.yaml
mise exec -- git commit -m "feat(media): stage tautulli application"
```

### Task 3: Add the Dedicated Media Alerts Kustomization and Promtool Tests

**Files:**
- Create: `kubernetes/apps/media/alerts/ks.yaml`
- Create: `kubernetes/apps/media/alerts/app/kustomization.yaml`
- Create: `kubernetes/apps/media/alerts/app/prometheusrule.yaml`
- Create: `scripts/validate/media-alerts.sh`
- Create: `tests/prometheus/media-alerts_test.yaml`
- Modify: `kubernetes/apps/media/kustomization.yaml`
- Modify: `kubernetes/mod.just`
- Modify: `tests/catalog.yaml`

**Interfaces:**
- Consumes: Gatus metric `gatus_results_endpoint_success` with labels `group` and `name`; kube-state-metrics PVC phase metric; Prometheus Operator CRD from `kube-prometheus-stack`.
- Produces: Flux Kustomization `media-alerts`, PrometheusRule `media/media-alerts`, validation ID `validation.media-alerts`, and recipe `just kube media-alerts-validate`.

- [ ] **Step 1: Write the promtool fixture before the rule exists**

Create `tests/prometheus/media-alerts_test.yaml` with these exact scenarios. Keep `evaluation_interval: 1m`, use the alert names and labels verbatim, and include each rule's annotations from Step 4 in its firing expectation:

```yaml
rule_files:
  - rules.yaml
evaluation_interval: 1m
tests:
  - interval: 1m
    input_series:
      - series: 'gatus_results_endpoint_success{group="Media", name="plex"}'
        values: '1x3 0x16 1x5'
      - series: 'gatus_results_endpoint_success{group="Media", name="seerr"}'
        values: '1x3 0x16 1x5'
      - series: 'gatus_results_endpoint_success{group="Media", name="qbittorrent-vpn"}'
        values: '0x24'
    alert_rule_test:
      - eval_time: 17m
        alertname: MediaEndpointDown
        exp_alerts: []
      - eval_time: 18m
        alertname: MediaEndpointDown
        exp_alerts:
          - exp_labels: {severity: warning, group: Media, name: plex}
            exp_annotations:
              summary: Media endpoint plex is down
              description: The Media/plex Gatus endpoint has failed continuously for 15 minutes.
          - exp_labels: {severity: warning, group: Media, name: seerr}
            exp_annotations:
              summary: Media endpoint seerr is down
              description: The Media/seerr Gatus endpoint has failed continuously for 15 minutes.
      - eval_time: 20m
        alertname: MediaEndpointDown
        exp_alerts: []

  - interval: 1m
    input_series:
      - series: 'gatus_results_endpoint_success{group="Platform", name="ntfy"}'
        values: '1x24'
      - series: 'gatus_results_endpoint_success{group="Media", name="plex"}'
        values: '_x18 1x6'
    alert_rule_test:
      - eval_time: 14m
        alertname: MediaEndpointsProbeMissing
        exp_alerts: []
      - eval_time: 16m
        alertname: MediaEndpointsProbeMissing
        exp_alerts:
          - exp_labels: {severity: warning, group: Media}
            exp_annotations:
              summary: All media endpoint probe metrics are missing
              description: Gatus has exposed no Media endpoint success series for 15 minutes.
      - eval_time: 20m
        alertname: MediaEndpointsProbeMissing
        exp_alerts: []

  - interval: 1m
    input_series:
      - series: 'gatus_results_endpoint_success{group="Media", name="seerr"}'
        values: '1x24'
      - series: 'gatus_results_endpoint_success{group="Media", name="plex"}'
        values: '_x18 1x6'
    alert_rule_test:
      - eval_time: 14m
        alertname: PlexProbeMissing
        exp_alerts: []
      - eval_time: 16m
        alertname: PlexProbeMissing
        exp_alerts:
          - exp_labels: {severity: warning, group: Media, name: plex}
            exp_annotations:
              summary: Plex probe metric is missing
              description: The Media/plex Gatus success series has been absent for 15 minutes.
      - eval_time: 20m
        alertname: PlexProbeMissing
        exp_alerts: []

  - interval: 1m
    input_series:
      - series: 'kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="other", phase="Bound"}'
        values: '1x14'
      - series: 'kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="plex", phase="Bound"}'
        values: '_x8 1x6'
    alert_rule_test:
      - eval_time: 4m
        alertname: PlexPersistentVolumeClaimNotBound
        exp_alerts: []
      - eval_time: 6m
        alertname: PlexPersistentVolumeClaimNotBound
        exp_alerts:
          - exp_labels: {severity: critical, namespace: media, persistentvolumeclaim: plex, phase: Bound}
            exp_annotations:
              summary: Plex database claim is absent or unbound
              description: The media/plex PVC has not reported Bound for five minutes; Plex library state is at risk.
      - eval_time: 10m
        alertname: PlexPersistentVolumeClaimNotBound
        exp_alerts: []
```

- [ ] **Step 2: Create and register the failing media-alert validator**

Create `scripts/validate/media-alerts.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

base='kubernetes/apps/media/alerts'
ks="$base/ks.yaml"
app_kustomization="$base/app/kustomization.yaml"
rule="$base/app/prometheusrule.yaml"
test_src='tests/prometheus/media-alerts_test.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-media-alerts-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$app_kustomization" "$rule" "$test_src"; do
  [[ -f "$f" ]] || { echo "Missing media alerts source: $f" >&2; exit 1; }
done
rg -qx '  - ./alerts/ks.yaml' kubernetes/apps/media/kustomization.yaml
[[ "$(yq -r '.metadata.name' "$ks")" == 'media-alerts' ]]
[[ "$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")" == 'kube-prometheus-stack' ]]
[[ "$(yq -r '.spec.suspend // false' "$ks")" == 'false' ]]
[[ "$(yq -r '.kind' "$rule")" == 'PrometheusRule' ]]
[[ "$(yq -r '.metadata.namespace' "$rule")" == 'media' ]]

mapfile -t media_rule_files < <(rg --files kubernetes/apps/media | rg '/app/prometheusrule\.yaml$' | sort)
expected_rule_files=(
  'kubernetes/apps/media/alerts/app/prometheusrule.yaml'
  'kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml'
)
[[ "${media_rule_files[*]}" == "${expected_rule_files[*]}" ]] || {
  echo 'Media PrometheusRules must live in media/alerts; qbittorrent is the only named legacy exception.' >&2
  printf 'Found: %s\n' "${media_rule_files[@]}" >&2
  exit 1
}

kustomize build "$base/app" >/dev/null
yq -o=yaml '.spec' "$rule" >"$temp_dir/rules.yaml"
cp "$test_src" "$temp_dir/media-alerts_test.yaml"
promtool check rules "$temp_dir/rules.yaml"
promtool test rules "$temp_dir/media-alerts_test.yaml"
echo 'Media alert placement, Prometheus syntax, and temporal/matcher tests passed.'
```

Add the `media-alerts-validate` recipe to `kubernetes/mod.just`, add `validation.media-alerts` beside `validation.tautulli`, and add both IDs to `executions.ci`:

```just
# Validate the isolated media-alerts Flux dependency/placement contract, then extract the
# manifest rule spec and run promtool syntax and temporal/matcher unit tests.
media-alerts-validate: require-bash
    @scripts/validate/media-alerts.sh
```

```yaml
  - metadata: {id: validation.media-alerts, source: validation, framework: bash, suite: ci, tier: offline, target: media-alerts, scenario: source, scope: system, intent: regression, mutates_cluster: false, execution_owner: shared}
    confirmation: {type: none, variable: null, expected: null}
    runner: {command: "mise exec -- just kube media-alerts-validate", implementation: scripts/validate/media-alerts.sh}
    native_results: {strategy: wrapper-junit}
```

- [ ] **Step 3: Run the validator and prove the rule source is absent**

Run:

```bash
mise exec -- just kube media-alerts-validate
```

Expected: FAIL with `Missing media alerts source: kubernetes/apps/media/alerts/ks.yaml`.

- [ ] **Step 4: Create the isolated Flux resources and the four PR 1 rules**

Create `kubernetes/apps/media/alerts/ks.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: media-alerts
  namespace: flux-system
spec:
  dependsOn:
    - name: kube-prometheus-stack
  interval: 1h
  path: ./kubernetes/apps/media/alerts/app
  prune: true
  retryInterval: 1m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  suspend: false
  timeout: 10m
  wait: true
```

Create `kubernetes/apps/media/alerts/app/kustomization.yaml`:

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./prometheusrule.yaml
```

Create `kubernetes/apps/media/alerts/app/prometheusrule.yaml`:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: media-alerts
  namespace: media
  labels:
    app.kubernetes.io/name: media-alerts
spec:
  groups:
    - name: media-availability
      rules:
        - alert: MediaEndpointDown
          expr: gatus_results_endpoint_success{group="Media", name!="qbittorrent-vpn"} == 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: 'Media endpoint {{ $labels.name }} is down'
            description: 'The Media/{{ $labels.name }} Gatus endpoint has failed continuously for 15 minutes.'
        - alert: MediaEndpointsProbeMissing
          expr: absent(gatus_results_endpoint_success{group="Media"})
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: All media endpoint probe metrics are missing
            description: Gatus has exposed no Media endpoint success series for 15 minutes.
        - alert: PlexProbeMissing
          expr: absent(gatus_results_endpoint_success{group="Media", name="plex"})
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: Plex probe metric is missing
            description: The Media/plex Gatus success series has been absent for 15 minutes.
    - name: media-persistence
      rules:
        - alert: PlexPersistentVolumeClaimNotBound
          expr: absent(kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="plex", phase="Bound"} == 1)
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: Plex database claim is absent or unbound
            description: The media/plex PVC has not reported Bound for five minutes; Plex library state is at risk.
```

- [ ] **Step 5: Wire `media-alerts` into the media root**

Add:

```yaml
  - ./alerts/ks.yaml
```

Do not add a KPS dependency to `media`, `plex`, `tautulli`, or qBittorrent.

- [ ] **Step 6: Run promtool and placement validation**

Run:

```bash
mise exec -- just kube media-alerts-validate
mise exec -- just kube kubeconform
```

Expected: `promtool check rules` and `promtool test rules` pass; the placement validator sees exactly the new central rule and the qBittorrent exception.

- [ ] **Step 7: Commit the media alerts**

```bash
mise exec -- git add kubernetes/apps/media/alerts kubernetes/apps/media/kustomization.yaml scripts/validate/media-alerts.sh tests/prometheus/media-alerts_test.yaml kubernetes/mod.just tests/catalog.yaml
mise exec -- git commit -m "feat(monitoring): add tested media alerts"
```

### Task 4: Add the Tautulli Live Verifier and Catalog Entry

**Files:**
- Create: `scripts/verify/tautulli.sh`
- Modify: `kubernetes/mod.just`
- Modify: `tests/catalog.yaml`

**Interfaces:**
- Consumes: Kustomization/HelmRelease/Deployment/HTTPRoute `tautulli`, `HOMELAB_GATEWAY_VIP`, and `HOMELAB_DNS_RESOLVER`.
- Produces: verification ID `verification.tautulli` and guarded read-only recipe `just kube tautulli-verify`.

- [ ] **Step 1: Create the liveness verifier**

Create `scripts/verify/tautulli.sh` with executable mode. It must perform the existing Seerr checks and compare exact status codes without following redirects:

```bash
#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/network.sh

[[ "$#" -eq 1 ]] || { echo 'Usage: tautulli.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
ns='media'
host='tautulli.lab.supermorphic.com'
gateway_ip="$HOMELAB_GATEWAY_VIP"
temp_dir="$(mktemp -d /tmp/homelab-talos-tautulli-verify.XXXXXX)"
proxy_pid=''
cleanup() {
  [[ -z "$proxy_pid" ]] || kill "$proxy_pid" >/dev/null 2>&1 || true
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT

[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization tautulli --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'tautulli Kustomization not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease tautulli --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'tautulli HelmRelease not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/tautulli --timeout=5m

accepted=false
for _ in {1..24}; do
  [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get httproute tautulli --output jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)" == 'True' ]] && { accepted=true; break; }
  sleep 5
done
[[ "$accepted" == 'true' ]] || { echo 'tautulli HTTPRoute was not Accepted.' >&2; exit 1; }
[[ "$(dig +short @"$HOMELAB_DNS_RESOLVER" "$host" A | sort -u)" == "$gateway_ip" ]] || { echo "DNS for $host does not resolve to $gateway_ip." >&2; exit 1; }

# kubectl proxy is read-only here. The API server originates the request to the ClusterIP
# Service, giving an exact direct-Service status without depending on tools in the app image.
kubectl --kubeconfig "$kubeconfig" proxy --address 127.0.0.1 --port 0 >"$temp_dir/proxy.log" 2>&1 &
proxy_pid="$!"
proxy_port=''
for _ in {1..20}; do
  proxy_port="$(sed -nE 's/^Starting to serve on 127\.0\.0\.1:([0-9]+)$/\1/p' "$temp_dir/proxy.log")"
  [[ -n "$proxy_port" ]] && break
  kill -0 "$proxy_pid" 2>/dev/null || { cat "$temp_dir/proxy.log" >&2; exit 1; }
  sleep 1
done
[[ -n "$proxy_port" ]] || { echo 'kubectl proxy did not publish a local port.' >&2; exit 1; }
service_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 --max-redirs 0 "http://127.0.0.1:${proxy_port}/api/v1/namespaces/media/services/tautulli/proxy/status")"
[[ "$service_status" == '200' ]] || { echo "tautulli /status returned $service_status through the in-cluster Service proxy, expected exact 200." >&2; exit 1; }

gateway_status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 15 --max-redirs 0 --resolve "$host:443:$gateway_ip" "https://$host/status")"
[[ "$gateway_status" == '200' ]] || { echo "tautulli /status returned $gateway_status through the gateway, expected exact 200." >&2; exit 1; }

echo "Tautulli liveness passed: resources Ready, route Accepted, DNS correct, and /status returned exact $service_status through the Service and $gateway_status through the gateway."
```

The API-server Service proxy is read-only and originates the upstream request inside the cluster. Do not describe either status check as proving Plex connectivity; the real playback gate owns that claim.

- [ ] **Step 2: Register verification recipe and catalog metadata**

Add to `kubernetes/mod.just`:

```just
# Verify live Tautulli resources, route, DNS, and exact non-redirecting HTTP 200 responses
# from /status through the Service and internal gateway. Operator-only/read-only; not in ci.
tautulli-verify: require-bash
    @scripts/test/run-catalog-suite.sh verification.tautulli -- scripts/verify/tautulli.sh {{quote(kubeconfig)}}
```

Add `verification.tautulli` to the verification campaign beside Seerr and register:

```yaml
  - metadata: {id: verification.tautulli, source: verification, framework: bash, suite: media, tier: verification, target: tautulli, scenario: null, scope: application, intent: acceptance, mutates_cluster: false, execution_owner: human}
    confirmation: {type: none, variable: null, expected: null}
    runner: {command: "mise exec -- just kube tautulli-verify", implementation: scripts/verify/tautulli.sh}
    native_results: {strategy: wrapper-junit}
```

- [ ] **Step 3: Validate syntax and catalog ownership**

Run:

```bash
mise exec -- bash -n scripts/verify/tautulli.sh
mise exec -- just test catalog-validate
```

Expected: both pass. Do not run the live verifier before deployment.

- [ ] **Step 4: Commit the verifier**

```bash
mise exec -- git add scripts/verify/tautulli.sh kubernetes/mod.just tests/catalog.yaml
mise exec -- git commit -m "feat(verification): add tautulli acceptance check"
```

### Task 5: Add Guarded Rollout and Homepage Secret Workflows

**Files:**
- Modify: `.just/bootstrap.just:1357`
- Modify: `.just/repository.just:708-750,1206`
- Modify: `README.md:199-287`

**Interfaces:**
- Consumes: `require_deployed_source`, the validation/verifier recipes from Tasks 2–4, and the repository SOPS recipient policy.
- Produces: `just bootstrap media-app tautulli`, confirmation `MEDIA_APP_BOOTSTRAP_CONFIRM=bootstrap:media-app:tautulli`, and `just repo homepage-tautulli-secrets`.

- [ ] **Step 1: Add the parameterized media-app bootstrap recipe**

Add this recipe without changing the existing Seerr or FlareSolverr recipes:

```just
# Reconcile a suspended config-only media app after guarded checks, then verify.
# Operator-run. The allowlist intentionally contains only Tautulli.
media-app app:
    #!/usr/bin/env bash
    set -euo pipefail

    app='{{app}}'
    case "$app" in
      tautulli) ;;
      *) echo 'Usage: just bootstrap media-app tautulli' >&2; exit 1 ;;
    esac
    kubeconfig='{{kubeconfig}}'
    owner='7yXwscXEzv6phzUnKfrw'
    repository='homelab-talos'
    expected_origin="https://github.com/${owner}/${repository}.git"
    expected_confirmation="bootstrap:media-app:$app"
    ks="kubernetes/apps/media/$app/ks.yaml"
    resumed=false
    bootstrap_complete=false
    cleanup_media_app() {
      if [[ "$bootstrap_complete" != 'true' && "$resumed" == 'true' ]]; then
        echo "$app did not pass; suspending it while preserving its resources." >&2
        flux suspend kustomization "$app" --namespace flux-system --kubeconfig "$kubeconfig" >/dev/null 2>&1 || true
      fi
    }
    trap cleanup_media_app EXIT

    [[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig; run just talos kubeconfig." >&2; exit 1; }
    [[ "$(git remote get-url origin)" == "$expected_origin" ]]
    source scripts/lib/rollout.sh
    require_deployed_source "$app bootstrap" \
      .just/bootstrap.just kubernetes/mod.just \
      scripts/lib/rollout.sh scripts/lib/network.sh \
      scripts/validate/tautulli.sh scripts/validate/media-alerts.sh \
      scripts/verify/tautulli.sh tests/catalog.yaml \
      tests/prometheus/media-alerts_test.yaml \
      kubernetes/apps/media/kustomization.yaml \
      kubernetes/apps/media/namespace \
      kubernetes/apps/media/alerts \
      "kubernetes/apps/media/$app"
    [[ "$(yq -r '.spec.suspend' "$ks")" == 'true' ]] || {
      echo "$app must be staged suspended in Git." >&2
      exit 1
    }

    just kube tautulli-validate
    just kube media-alerts-validate
    flux reconcile source git flux-system --kubeconfig "$kubeconfig"
    just kube flux-verify
    flux reconcile kustomization cluster-apps --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 10m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization "$app" --output jsonpath='{.spec.suspend}')" == 'true' ]] || {
      echo "$app is not suspended in the live cluster." >&2
      exit 1
    }

    [[ "${MEDIA_APP_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo "Set MEDIA_APP_BOOTSTRAP_CONFIRM='$expected_confirmation' after reviewing both validators." >&2
      exit 1
    }

    resumed=true
    flux resume kustomization "$app" --namespace flux-system --kubeconfig "$kubeconfig"
    flux reconcile kustomization "$app" --namespace flux-system --with-source --kubeconfig "$kubeconfig" --timeout 15m
    kubectl --kubeconfig "$kubeconfig" --namespace flux-system wait --for=condition=Ready "kustomization/$app" --timeout=15m
    just kube tautulli-verify
    bootstrap_complete=true
    echo "$app liveness passed. Complete authentication, Plex connection, exact-status, library, and playback gates before activation."
```

- [ ] **Step 2: Add the operator-only Homepage Secret recipe**

Add this complete Tautulli recipe:

```just
homepage-tautulli-secrets:
    #!/usr/bin/env bash
    set -euo pipefail

    expected_confirmation='write:monitoring:homepage-tautulli:sops'
    target='kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml'
    temp_dir="$(mktemp -d /tmp/homelab-talos-homepage-tautulli.XXXXXX)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    umask 077

    just repo secrets
    [[ -n "${TAUTULLI_API_KEY:-}" ]] || {
      echo 'Set TAUTULLI_API_KEY to the API key generated in Tautulli.' >&2
      exit 1
    }
    [[ "${HOMEPAGE_TAUTULLI_SECRETS_CONFIRM:-}" == "$expected_confirmation" ]] || {
      echo 'Refusing to write the Homepage Tautulli Secret.' >&2
      echo "Set HOMEPAGE_TAUTULLI_SECRETS_CONFIRM='$expected_confirmation' after reviewing the target." >&2
      exit 1
    }

    export TAUTULLI_API_KEY
    yq -n \
      '.apiVersion = "v1" |
       .kind = "Secret" |
       .metadata.name = "homepage-tautulli" |
       .metadata.namespace = "homepage" |
       .type = "Opaque" |
       .stringData."apiKey" = strenv(TAUTULLI_API_KEY)' \
      >"$temp_dir/homepage-tautulli.yaml"

    sops --encrypt --filename-override "$target" \
      "$temp_dir/homepage-tautulli.yaml" >"$temp_dir/homepage-tautulli.sops.yaml"
    [[ "$(sops filestatus "$temp_dir/homepage-tautulli.sops.yaml" | yq -r '.encrypted')" == 'true' ]]
    [[ "$(yq -r '.sops.age[].recipient' "$temp_dir/homepage-tautulli.sops.yaml" | sort -u)" == "$(yq -r '.creation_rules[1].age' .sops.yaml)" ]]
    ! rg -Fq -- "$TAUTULLI_API_KEY" "$temp_dir/homepage-tautulli.sops.yaml"

    mv -- "$temp_dir/homepage-tautulli.sops.yaml" "$target"
    echo "Wrote SOPS-encrypted $target (homepage-tautulli in homepage)."
```

Do not run this recipe in PR 1.

- [ ] **Step 3: Update the rollout-guard invariant in the same change**

Change exactly:

```just
@test "$(rg -c 'require_deployed_source ' .just/bootstrap.just kubernetes/mod.just | awk -F: '{sum += $2} END {print sum}')" -eq 25  # Update when adding/removing a guarded rollout recipe.
```

- [ ] **Step 4: Add README command-table entries**

Add rows for:

```markdown
| `just repo homepage-tautulli-secrets` | Write only the encrypted Tautulli API key used by the Homepage widget | `SOPS_AGE_KEY`[`_FILE`]; `TAUTULLI_API_KEY`; `HOMEPAGE_TAUTULLI_SECRETS_CONFIRM=write:monitoring:homepage-tautulli:sops` | Tautulli activation; operator-only tracked ciphertext write |
| `just kube tautulli-validate` | Validate suspended/active Tautulli source, storage, probes, route, integrations, and pinned render | — | Cluster-independent; included in `just ci` |
| `just kube media-alerts-validate` | Validate isolated media alert placement and run promtool syntax/unit tests | — | Cluster-independent; included in `just ci` |
| `just bootstrap media-app tautulli` | Guardedly resume staged Tautulli and run liveness acceptance | `MEDIA_APP_BOOTSTRAP_CONFIRM=bootstrap:media-app:tautulli` | Operator-only; mutating after confirmation |
| `just kube tautulli-verify` | Verify live Tautulli resources, route, DNS, exact health status, Gatus series, and loaded rules | `.kube/config` | Operator-only and read-only |
```

- [ ] **Step 5: Validate recipe syntax and guard count**

Run:

```bash
mise exec -- just --list >/dev/null
mise exec -- just repo verify
```

Expected: recipe parsing passes, the guard occurrence is exactly `25`, and repository verification passes.

- [ ] **Step 6: Commit guarded workflows**

```bash
mise exec -- git add .just/bootstrap.just .just/repository.just README.md
mise exec -- git commit -m "feat(workflows): add tautulli rollout guards"
```

### Task 6: Document the Two-PR Tautulli Runbook

**Files:**
- Modify: `docs/arr-stack-startup.md:924-1030`

**Interfaces:**
- Consumes: Exact commands and gates from Tasks 2–5.
- Produces: An operator sequence that never activates unauthenticated Tautulli and never promises Plex Logs.

- [ ] **Step 1: Add a Tautulli section after Seerr**

Document all of the following literal values and order:

````markdown
## Tautulli

Tautulli begins with an empty database; watch history starts at this rollout. It reads Plex
through `http://plex.media.svc.cluster.local:32400` and never mounts Plex or shared-media
storage. The Tautulli **Plex Logs** viewer is therefore intentionally unavailable.

After PR 1 is merged, the operator runs:

```bash
export MEDIA_APP_BOOTSTRAP_CONFIRM='bootstrap:media-app:tautulli'
mise exec -- just bootstrap media-app tautulli
unset MEDIA_APP_BOOTSTRAP_CONFIRM
```

In the Tautulli UI, complete these steps in order:

1. Enable Tautulli web authentication before entering Plex or API credentials.
2. Connect Plex at `http://plex.media.svc.cluster.local:32400` with the operator-supplied Plex token.
3. Generate the Tautulli API key.
4. Confirm at least one Plex library appears.
5. Play authorized media and require the session to appear in Tautulli history.

Before PR 2, record the chosen authentication mode and prove `/status` returns exact HTTP
`200` with redirects disabled both from the cluster and through
`tautulli.lab.supermorphic.com`. A 3xx is a failed gate even if Kubernetes probes are green.
Run `mise exec -- just kube tautulli-verify` after authentication is enabled.

The operator creates the Homepage Secret only after the API key exists:

```bash
printf 'Tautulli API key: '
IFS= read -r -s TAUTULLI_API_KEY
printf '\n'
export TAUTULLI_API_KEY
export HOMEPAGE_TAUTULLI_SECRETS_CONFIRM='write:monitoring:homepage-tautulli:sops'
mise exec -- just repo homepage-tautulli-secrets
unset TAUTULLI_API_KEY HOMEPAGE_TAUTULLI_SECRETS_CONFIRM
```

Commit only the generated encrypted `homepage-tautulli.sops.yaml`; never commit the key.
PR 2 may set `suspend: false` only after authentication, exact status, verifier, library,
and real-playback gates all pass.
````

- [ ] **Step 2: Run documentation and link validation**

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
```

Expected: links and pre-commit checks pass; new text contains no `Phase N` wording.

- [ ] **Step 3: Commit the runbook**

```bash
mise exec -- git add docs/arr-stack-startup.md
mise exec -- git commit -m "docs(media): add tautulli rollout runbook"
```

### Task 7: Validate and Publish PR 1 Without Activating Tautulli

**Files:**
- Verify only; no new file ownership.

**Interfaces:**
- Consumes: Every PR 1 deliverable from Tasks 1–6.
- Produces: A reviewable PR with Tautulli suspended and generic/Plex media alerts live on merge.

- [ ] **Step 1: Verify PR 1's negative activation boundary**

Run:

```bash
mise exec -- yq -r '.spec.suspend' kubernetes/apps/media/tautulli/ks.yaml
mise exec -- rg -n 'name: tautulli|widget\.type.*tautulli|homepage-tautulli' kubernetes/apps/monitoring/gatus/app/values.yaml kubernetes/apps/media/tautulli/app/httproute.yaml kubernetes/apps/monitoring/homepage/app/deployment.yaml kubernetes/apps/monitoring/homepage/app/kustomization.yaml || true
mise exec -- rg -n 'TautulliProbeMissing|TautulliPersistentVolumeClaimNotBound' kubernetes/apps/media/alerts/app/prometheusrule.yaml tests/prometheus/media-alerts_test.yaml || true
```

Expected: suspend prints `true`; both searches print nothing. The Secret-generation recipe may mention `homepage-tautulli`, but no Homepage manifest may do so yet.

- [ ] **Step 2: Run canonical validation**

Run:

```bash
mise exec -- just ci
```

Expected: PASS, including `validation.tautulli`, `validation.media-alerts`, media policy, promtool, kubeconform, and rollout-guard count `25`.

- [ ] **Step 3: Review the exact PR 1 footprint**

Run:

```bash
mise exec -- git status --short
mise exec -- git diff origin/main...HEAD --stat
mise exec -- git log --oneline origin/main..HEAD
```

Expected: only the PR 1 files in the file map are changed; no plaintext Secret or activation integration is present.

- [ ] **Step 4: Fetch immediately before push and rebase only if clean**

```bash
mise exec -- git fetch origin
mise exec -- git status --porcelain
mise exec -- git rebase origin/main
```

Expected: clean worktree and scoped commits above current `origin/main`. Push the feature branch and open PR 1; do not enable auto-merge or merge without fresh operator authorization.

---

## Operator Gate Between PRs

### Task 8: Roll Out, Authenticate, and Prove Real Plex Analytics

**Files:**
- Operational evidence only until every gate passes.

**Interfaces:**
- Consumes: PR 1 merged at current `origin/main`, operator kubeconfig, Plex token, and a real authorized playback.
- Produces: Chosen auth mode, exact direct/gateway `/status` evidence, Tautulli API key, confirmed library, and playback-history evidence.

- [ ] **Step 1: Confirm PR 1 is the deployed production boundary**

Run:

```bash
mise exec -- git fetch origin
mise exec -- git status --short --branch
mise exec -- git rev-parse origin/main
```

Expected: PR 1 is present on `origin/main`; the guarded rollout's source closure matches that commit.

- [ ] **Step 2: Operator runs the guarded rollout**

```bash
export MEDIA_APP_BOOTSTRAP_CONFIRM='bootstrap:media-app:tautulli'
mise exec -- just bootstrap media-app tautulli
unset MEDIA_APP_BOOTSTRAP_CONFIRM
```

Expected: validators pass before mutation, Tautulli resumes and becomes Ready, the rollout completes, and `/status` is exact `200` through the gateway. On failure after resume, the cleanup trap re-suspends Tautulli while preserving the PVC/resources.

- [ ] **Step 3: Complete first-run settings in the required order**

In the UI:

1. Enable web authentication and record the exact mode name shown by Tautulli.
2. Configure Plex URL `http://plex.media.svc.cluster.local:32400` and the operator's Plex token.
3. Generate the API key without pasting it into Git, logs, chat, or command arguments.
4. Confirm at least one Plex library appears.
5. Start a real authorized playback and confirm it appears in Tautulli history.

- [ ] **Step 4: Re-run both exact status checks after authentication**

Run:

```bash
mise exec -- just kube tautulli-verify
```

Expected: PASS with exact Service and gateway statuses `200`, not 3xx.

- [ ] **Step 5: Decide whether the main plan can continue**

Continue to Task 9 only if all five gates hold: authentication enabled, both `/status` paths exact `200`, `tautulli-verify` green, a Plex library visible, and a real playback recorded.

If either status is not `200`, stop. Record the exact status and `Location` response header, then amend this plan with the observed login path and the accepted TCP-probe fallback before changing PR 2 source. Do not proceed with the remaining tasks unchanged.

---

## PR 2 — Activation and Live Integration Proof

### Task 9: Add Tautulli-Specific Alert Rules and Tests

**Files:**
- Modify: `kubernetes/apps/media/alerts/app/prometheusrule.yaml`
- Modify: `tests/prometheus/media-alerts_test.yaml`

**Interfaces:**
- Consumes: A live Tautulli PVC and the PR 2 Gatus series added in Task 10.
- Produces: `TautulliProbeMissing` and `TautulliPersistentVolumeClaimNotBound` with temporal and unrelated-series matcher coverage.

- [ ] **Step 1: Add failing test cases for both activation-only rules**

Append:

```yaml
  - interval: 1m
    input_series:
      - series: 'gatus_results_endpoint_success{group="Media", name="plex"}'
        values: '1x24'
      - series: 'gatus_results_endpoint_success{group="Media", name="tautulli"}'
        values: '_x18 1x6'
    alert_rule_test:
      - eval_time: 14m
        alertname: TautulliProbeMissing
        exp_alerts: []
      - eval_time: 16m
        alertname: TautulliProbeMissing
        exp_alerts:
          - exp_labels: {severity: warning, group: Media, name: tautulli}
            exp_annotations:
              summary: Tautulli probe metric is missing
              description: The Media/tautulli Gatus success series has been absent for 15 minutes.
      - eval_time: 20m
        alertname: TautulliProbeMissing
        exp_alerts: []

  - interval: 1m
    input_series:
      - series: 'kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="plex", phase="Bound"}'
        values: '1x14'
      - series: 'kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="tautulli", phase="Bound"}'
        values: '_x8 1x6'
    alert_rule_test:
      - eval_time: 4m
        alertname: TautulliPersistentVolumeClaimNotBound
        exp_alerts: []
      - eval_time: 6m
        alertname: TautulliPersistentVolumeClaimNotBound
        exp_alerts:
          - exp_labels: {severity: warning, namespace: media, persistentvolumeclaim: tautulli, phase: Bound}
            exp_annotations:
              summary: Tautulli database claim is absent or unbound
              description: The media/tautulli PVC has not reported Bound for five minutes; watch history persistence is at risk.
      - eval_time: 10m
        alertname: TautulliPersistentVolumeClaimNotBound
        exp_alerts: []
```

- [ ] **Step 2: Run promtool and observe missing-rule failures**

Run:

```bash
mise exec -- just kube media-alerts-validate
```

Expected: FAIL because both test alert names are absent from the manifest.

- [ ] **Step 3: Add the two rules to their existing groups**

Add `TautulliProbeMissing` after `PlexProbeMissing`:

```yaml
        - alert: TautulliProbeMissing
          expr: absent(gatus_results_endpoint_success{group="Media", name="tautulli"})
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: Tautulli probe metric is missing
            description: The Media/tautulli Gatus success series has been absent for 15 minutes.
```

Add the PVC rule after the Plex PVC rule:

```yaml
        - alert: TautulliPersistentVolumeClaimNotBound
          expr: absent(kube_persistentvolumeclaim_status_phase{namespace="media", persistentvolumeclaim="tautulli", phase="Bound"} == 1)
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: Tautulli database claim is absent or unbound
            description: The media/tautulli PVC has not reported Bound for five minutes; watch history persistence is at risk.
```

- [ ] **Step 4: Run alert validation**

```bash
mise exec -- just kube media-alerts-validate
```

Expected: all six rules pass syntax and temporal/matcher tests.

- [ ] **Step 5: Commit alert activation**

```bash
mise exec -- git add kubernetes/apps/media/alerts/app/prometheusrule.yaml tests/prometheus/media-alerts_test.yaml
mise exec -- git commit -m "feat(monitoring): add tautulli alert coverage"
```

### Task 10: Add Gatus and Homepage Integrations and Persist Activation

**Files:**
- Modify: `kubernetes/apps/media/tautulli/ks.yaml`
- Modify: `kubernetes/apps/media/tautulli/app/httproute.yaml`
- Modify: `kubernetes/apps/monitoring/gatus/app/values.yaml`
- Create: `kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml` (operator only)
- Modify: `kubernetes/apps/monitoring/homepage/app/deployment.yaml`
- Modify: `kubernetes/apps/monitoring/homepage/app/kustomization.yaml`

**Interfaces:**
- Consumes: API key created in Task 8 and the guarded Secret recipe from Task 5.
- Produces: Active Tautulli Flux state, Homepage widget env/annotations, and Gatus series `{group="Media", name="tautulli"}`.

- [ ] **Step 1: Operator creates the encrypted Homepage Secret**

The operator runs locally; an agent must not handle the age key or API key:

```bash
printf 'Tautulli API key: '
IFS= read -r -s TAUTULLI_API_KEY
printf '\n'
export TAUTULLI_API_KEY
export HOMEPAGE_TAUTULLI_SECRETS_CONFIRM='write:monitoring:homepage-tautulli:sops'
mise exec -- just repo homepage-tautulli-secrets
unset TAUTULLI_API_KEY HOMEPAGE_TAUTULLI_SECRETS_CONFIRM
```

Expected: only `kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml` is created; `sops filestatus` reports encrypted and plaintext does not appear in Git output.

- [ ] **Step 2: Add the Tautulli Gatus endpoint**

Add after Seerr:

```yaml
    - name: tautulli
      group: Media
      url: "https://tautulli.lab.supermorphic.com/status"
      interval: 1m
      conditions:
        - "[STATUS] == 200"
```

- [ ] **Step 3: Add the optional Homepage API-key environment variable**

Add beside the Seerr variable:

```yaml
            - name: HOMEPAGE_VAR_TAUTULLI_API_KEY
              valueFrom:
                secretKeyRef:
                  name: homepage-tautulli
                  key: apiKey
                  optional: true
```

Add to Homepage resources:

```yaml
  - ./homepage-tautulli.sops.yaml
```

- [ ] **Step 4: Add the Homepage widget annotations**

Add to the Tautulli HTTPRoute:

```yaml
    gethomepage.dev/widget.type: "tautulli"
    gethomepage.dev/widget.url: "http://tautulli.media.svc.cluster.local:8181"
    gethomepage.dev/widget.key: "{{HOMEPAGE_VAR_TAUTULLI_API_KEY}}"
```

- [ ] **Step 5: Persist activation last**

Change exactly:

```yaml
  suspend: false
```

- [ ] **Step 6: Run activation-aware validation**

Run:

```bash
mise exec -- just kube tautulli-validate
mise exec -- just kube media-alerts-validate
mise exec -- just kube gatus-validate
mise exec -- just kube homepage-validate
```

Expected: all pass; the Tautulli validator proves the active state has exactly one Gatus endpoint, all three widget annotations, one optional env ref, one SOPS resource, and encrypted Secret metadata.

- [ ] **Step 7: Commit the activation integrations**

```bash
mise exec -- git add kubernetes/apps/media/tautulli/ks.yaml kubernetes/apps/media/tautulli/app/httproute.yaml kubernetes/apps/monitoring/gatus/app/values.yaml kubernetes/apps/monitoring/homepage/app/deployment.yaml kubernetes/apps/monitoring/homepage/app/kustomization.yaml kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml
mise exec -- git commit -m "feat(media): activate tautulli integrations"
```

### Task 11: Extend Live Verification to the Metric and Loaded Rules

**Files:**
- Modify: `scripts/verify/tautulli.sh`

**Interfaces:**
- Consumes: Prometheus API at `prometheus.lab.supermorphic.com`, Gatus Tautulli series, and the six alert names from Tasks 3 and 9.
- Produces: One end-to-end `verification.tautulli` check for app liveness, metric availability, rule loading, and evaluation health.

- [ ] **Step 1: Add Prometheus helper setup**

Source the existing helper and define:

```bash
source scripts/lib/flux-alerts.sh

prometheus_base_url='https://prometheus.lab.supermorphic.com'
prometheus_resolve="prometheus.lab.supermorphic.com:443:${gateway_ip}"
expected_rules=(
  MediaEndpointDown
  MediaEndpointsProbeMissing
  PlexProbeMissing
  TautulliProbeMissing
  PlexPersistentVolumeClaimNotBound
  TautulliPersistentVolumeClaimNotBound
)
```

- [ ] **Step 2: Verify the exact Gatus series exists**

Add after the gateway health check:

```bash
metric_response="$(
  flux_alerts_prometheus_query "$prometheus_base_url" "$prometheus_resolve" \
    'gatus_results_endpoint_success{group="Media", name="tautulli"}'
)"
[[ "$(yq -r '.status // ""' <<<"$metric_response")" == 'success' ]]
[[ "$(yq -r '[.data.result[] | select(.metric.group == "Media" and .metric.name == "tautulli")] | length' <<<"$metric_response")" -gt 0 ]] || {
  echo 'Prometheus has no gatus_results_endpoint_success{group="Media", name="tautulli"} series.' >&2
  exit 1
}
```

- [ ] **Step 3: Verify all six rule names are loaded and healthy**

Add:

```bash
rules_response="$(
  flux_alerts_prometheus_get "$prometheus_base_url" "$prometheus_resolve" \
    '/api/v1/rules?type=alert'
)"
[[ "$(yq -r '.status // ""' <<<"$rules_response")" == 'success' ]]
expected_rules_csv="$(IFS=,; echo "${expected_rules[*]}")"
mapfile -t media_rule_rows < <(
  EXPECTED_RULES="$expected_rules_csv" yq -r '
    .data.groups[]?.rules[]? |
    select(.name as $name | (strenv(EXPECTED_RULES) | split(",") | index($name))) |
    [.name, (.health // "unknown"), (.lastError // "")] | @tsv
  ' <<<"$rules_response"
)
[[ "${#media_rule_rows[@]}" -eq "${#expected_rules[@]}" ]] || {
  echo "Prometheus loaded ${#media_rule_rows[@]} of ${#expected_rules[@]} expected media rules." >&2
  exit 1
}
for row in "${media_rule_rows[@]}"; do
  IFS=$'\t' read -r rule_name rule_health rule_error <<<"$row"
  [[ "$rule_health" == 'ok' && -z "$rule_error" ]] || {
    echo "Prometheus rule $rule_name is unhealthy: ${rule_error:-no error text}." >&2
    exit 1
  }
done
```

Before accepting the count, also compare sorted loaded names with sorted `expected_rules` so a duplicate cannot hide a missing rule:

```bash
loaded_names="$(printf '%s\n' "${media_rule_rows[@]}" | cut -f1 | sort)"
expected_names="$(printf '%s\n' "${expected_rules[@]}" | sort)"
[[ "$loaded_names" == "$expected_names" ]]
```

- [ ] **Step 4: Update the success message and validate syntax**

The message must say exact `/status` `200`, the Tautulli Gatus series, and all six healthy loaded rules. Then run:

```bash
mise exec -- bash -n scripts/verify/tautulli.sh
mise exec -- just test catalog-validate
```

Expected: both pass.

- [ ] **Step 5: Commit live integration verification**

```bash
mise exec -- git add scripts/verify/tautulli.sh
mise exec -- git commit -m "feat(verification): check tautulli monitoring path"
```

### Task 12: Record the Observed Authentication Result

**Files:**
- Modify: `docs/arr-stack-startup.md`

**Interfaces:**
- Consumes: Exact auth-mode and status evidence recorded in Task 8.
- Produces: A runbook with no speculative authentication behavior.

- [ ] **Step 1: Replace the pre-activation recording instruction with observed facts**

Write two sentences. The first starts `Web authentication is enabled using **`, inserts the exact UI mode label recorded in Task 8, and ends `**.` The second is exactly: `With that mode active, GET /status returned exact HTTP 200 with redirects disabled both through the media/tautulli Service and through tautulli.lab.supermorphic.com.` Format the endpoint, status, Service name, and hostname as inline code. If the mode label was not recorded, stop and recover it from the live UI before editing.

- [ ] **Step 2: Validate documentation**

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
```

Expected: PASS with no provisional auth wording or new phase wording.

- [ ] **Step 3: Commit observed operations evidence**

```bash
mise exec -- git add docs/arr-stack-startup.md
mise exec -- git commit -m "docs(media): record tautulli activation"
```

### Task 13: Validate, Publish, and Verify PR 2

**Files:**
- Verify only; no new file ownership.

**Interfaces:**
- Consumes: Every PR 2 deliverable and Task 8's accepted live state.
- Produces: Active production source and end-to-end evidence satisfying the design definition of done.

- [ ] **Step 1: Run canonical cluster-independent validation**

```bash
mise exec -- just ci
```

Expected: PASS, including six promtool-tested alerts and activation-aware Tautulli checks.

- [ ] **Step 2: Verify the exact PR 2 footprint and ciphertext boundary**

```bash
mise exec -- git status --short
mise exec -- git diff origin/main...HEAD --stat
mise exec -- sops filestatus kubernetes/apps/monitoring/homepage/app/homepage-tautulli.sops.yaml
mise exec -- rg -n 'record the chosen authentication mode|insert the authentication mode' docs/arr-stack-startup.md || true
```

Expected: only PR 2 files from the file map plus PR 1 commits not yet on the branch base; SOPS reports encrypted; provisional-wording scan prints nothing.

- [ ] **Step 3: Fetch immediately before push and rebase only when clean**

```bash
mise exec -- git fetch origin
mise exec -- git status --porcelain
mise exec -- git rebase origin/main
mise exec -- just ci
```

Expected: clean rebase and a fresh passing CI run. Push the feature branch and open PR 2; do not enable auto-merge or merge without fresh operator authorization.

- [ ] **Step 4: After authorized merge, run guarded live verification**

The operator runs:

```bash
mise exec -- just kube tautulli-verify
mise exec -- just kube homepage-verify
```

Expected: Tautulli resources/route/DNS/health pass, the exact Gatus series exists, all six rules are loaded with `health: ok` and no `lastError`, and Homepage is healthy.

- [ ] **Step 5: Complete the only manual visual gate**

Open Homepage and confirm the Tautulli widget shows live stream counts rather than an error state. Reconfirm web authentication remains enabled, at least one Plex library is connected, and the Task 8 playback remains present in Tautulli history.

- [ ] **Step 6: Report completion evidence**

Report:

- every changed file grouped by PR;
- `mise exec -- just ci` result from each PR;
- operator-run bootstrap and live verifier results;
- chosen auth mode and both exact `/status` codes;
- playback-history and Homepage visual results;
- any remaining risk: UID 568 was inherited rather than measured before rollout, Gatus label names were verified only live, Plex Logs is structurally unavailable, and non-Plex/Tautulli media endpoint disappearance remains deliberately uncovered.
