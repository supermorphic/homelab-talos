#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/n8n-alert-activation.sh
source "$script_dir/../lib/n8n-alert-activation.sh"

base='kubernetes/apps/automation'
ns="$base/namespace/app/namespace.yaml"
public_base='kubernetes/apps/networking/public-webhook-gateway'
public_namespace="$public_base/app/namespace.yaml"
public_pool="$public_base/app/address-pool.yaml"
public_certificate="$public_base/app/certificate.yaml"
public_gateway="$public_base/app/gateway.yaml"
public_route="$public_base/route/httproute.yaml"
public_ks="$public_base/ks.yaml"
external_dns='kubernetes/apps/networking/external-dns/app/values.yaml'
postgresql_base="$base/n8n-postgresql"
postgresql_app="$postgresql_base/app"
postgresql_ks="$postgresql_base/ks.yaml"
postgresql_kustomization="$postgresql_app/kustomization.yaml"
postgresql_pvcs="$postgresql_app/persistentvolumeclaims.yaml"
postgresql_service="$postgresql_app/service.yaml"
postgresql_statefulset="$postgresql_app/statefulset.yaml"
postgresql_cronjob="$postgresql_app/cronjob.yaml"
postgresql_monitor="$postgresql_app/servicemonitor.yaml"
postgresql_policy="$postgresql_app/ciliumnetworkpolicy.yaml"
postgresql_init="$postgresql_app/scripts/init-database.sh"
postgresql_backup="$postgresql_app/scripts/backup.sh"
postgresql_status_sql="$postgresql_app/scripts/update-backup-status.sql"
postgresql_exporter="$postgresql_app/sql-exporter.yml"
n8n_base="$base/n8n"
n8n_app="$n8n_base/app"
n8n_ks="$n8n_base/ks.yaml"
n8n_kustomization="$n8n_app/kustomization.yaml"
n8n_source="$n8n_app/ocirepository.yaml"
n8n_release="$n8n_app/helmrelease.yaml"
n8n_values="$n8n_app/values.yaml"
n8n_pvc="$n8n_app/persistentvolumeclaim.yaml"
n8n_route="$n8n_app/httproute.yaml"
n8n_grant="$n8n_app/referencegrant.yaml"
n8n_monitor="$n8n_app/servicemonitor.yaml"
n8n_policy="$n8n_app/ciliumnetworkpolicy.yaml"
n8n_workflow="$n8n_app/workflows/platform-canary.json"
monitoring_alerts_kustomization='kubernetes/apps/monitoring/alerts/app/kustomization.yaml'
n8n_alerts='kubernetes/apps/monitoring/alerts/app/n8n.yaml'
n8n_alert_activation_lib='scripts/lib/n8n-alert-activation.sh'
gatus_kustomization='kubernetes/apps/monitoring/gatus/app/kustomization.yaml'
gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
gatus_canary_activation='kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml'
prometheus_config='kubernetes/apps/monitoring/kube-prometheus-stack/config/kustomization.yaml'
n8n_dashboard='kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/n8n-postgresql.json'
catalog='tests/catalog.yaml'
n8n_verifier='scripts/verify/n8n.sh'
n8n_verification_lib='scripts/lib/n8n-verification.sh'
n8n_verification_contract_test='scripts/test/n8n-verification-contract-test.sh'
n8n_persistence='scripts/test/scenarios/n8n-persistence.sh'
n8n_restore_drill='scripts/test/scenarios/n8n-restore-drill.sh'
n8n_smoke='tests/chainsaw/smoke/platform/n8n/chainsaw-test.yaml'
n8n_operations='docs/guides/n8n-operations.md'
n8n_recovery='docs/runbooks/n8n-recovery.md'
bootstrap_just='.just/bootstrap.just'
kubernetes_just='kubernetes/mod.just'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-validate.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

normalise_resource_path() {
  local path="$1"
  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done
  printf '%s\n' "$path"
}

validate_selected_sops_secret() {
  local owner="$1" resource="$2" target="$3" expected_name="$4"
  local expected_namespace="$5" expected_keys="$6" expected_recipient selected_resource
  local normalised_resource normalised_selected_resource selected=false
  local -a expected_recipients candidate_recipients

  [[ -f "$owner" ]] || return 0
  normalised_resource="$(normalise_resource_path "$resource")"
  while IFS= read -r selected_resource; do
    normalised_selected_resource="$(normalise_resource_path "$selected_resource")"
    [[ "$normalised_selected_resource" != "$normalised_resource" ]] || selected=true
  done < <(yq -r '.resources[]?' "$owner")
  [[ "$selected" == true ]] || return 0
  [[ -f "$target" ]] || {
    echo "Missing selected n8n SOPS Secret: $target." >&2
    exit 1
  }
  # shellcheck disable=SC2016 # yq reads target through its env() function.
  mapfile -t expected_recipients < <(
    target="$target" yq -r \
      '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
      .sops.yaml
  )
  [[ "${#expected_recipients[@]}" -eq 1 && -n "${expected_recipients[0]}" && \
    "${expected_recipients[0]}" != 'null' ]] || {
    echo "Unable to select exactly one SOPS age recipient for $target." >&2
    exit 1
  }
  expected_recipient="${expected_recipients[0]}"
  [[ "$(sops filestatus "$target" | yq -r '.encrypted')" == 'true' ]] || {
    echo "Selected n8n SOPS Secret is not encrypted: $target." >&2
    exit 1
  }
  mapfile -t candidate_recipients < <(yq -r '.sops.age[].recipient' "$target" | sort -u)
  [[ "${#candidate_recipients[@]}" -eq 1 && \
    "${candidate_recipients[0]}" == "$expected_recipient" ]] || {
    echo "Selected n8n SOPS Secret has an unexpected age recipient: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'has("data") | not' "$target")" == 'true' ]] || {
    echo "Selected n8n SOPS Secret must not contain data: $target." >&2
    exit 1
  }
  [[ "$(yq -r 'keys | sort | join(",")' "$target")" == \
    'apiVersion,kind,metadata,sops,stringData,type' ]] || {
    echo "Selected n8n SOPS Secret has an unexpected top-level schema: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.metadata | keys | sort | join(",")' "$target")" == 'name,namespace' && \
    "$(yq -r '.apiVersion' "$target")" == 'v1' && \
    "$(yq -r '.kind' "$target")" == 'Secret' && \
    "$(yq -r '.metadata.name' "$target")" == "$expected_name" && \
    "$(yq -r '.metadata.namespace' "$target")" == "$expected_namespace" && \
    "$(yq -r '.type' "$target")" == 'Opaque' ]] || {
    echo "Selected n8n SOPS Secret has an unexpected Secret contract: $target." >&2
    exit 1
  }
  [[ "$(yq -r '.stringData | keys | sort | join(",")' "$target")" == "$expected_keys" ]] || {
    echo "Selected n8n SOPS Secret has an unexpected key set: $target." >&2
    exit 1
  }
}

validate_postgresql_metrics_ingress() {
  local manifest="$1" metrics_identity
  metrics_identity="$(yq ea -r '
    select(.kind == "CiliumNetworkPolicy" and .metadata.name == "n8n-postgresql") |
    .spec.ingress[] |
    select(.toPorts[].ports[].port == "9399") |
    .fromEndpoints[].matchLabels |
    to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")
  ' "$manifest")"
  [[ "$metrics_identity" == \
    'app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring,operator.prometheus.io/name=kube-prometheus-stack-prometheus' ]] || {
    echo 'PostgreSQL metrics ingress must select only the pinned Prometheus workload identity.' >&2
    exit 1
  }
}

for file in "$base/kustomization.yaml" "$base/namespace/ks.yaml" \
  "$base/namespace/app/kustomization.yaml" "$ns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
for file in "$public_namespace" "$public_pool" "$public_certificate" "$public_gateway" \
  "$public_route" "$public_ks" "$public_base/app/kustomization.yaml" \
  "$public_base/route/kustomization.yaml" "$external_dns"; do
  [[ -f "$file" ]] || { echo "Missing n8n platform source: $file" >&2; exit 1; }
done
for file in "$postgresql_ks" "$postgresql_kustomization" "$postgresql_pvcs" \
  "$postgresql_service" "$postgresql_statefulset" "$postgresql_cronjob" \
  "$postgresql_monitor" "$postgresql_policy" "$postgresql_init" \
  "$postgresql_backup" "$postgresql_status_sql" "$postgresql_exporter"; do
  [[ -f "$file" ]] || { echo "Missing n8n PostgreSQL source: $file" >&2; exit 1; }
done
for file in "$n8n_ks" "$n8n_kustomization" "$n8n_source" "$n8n_release" \
  "$n8n_values" "$n8n_pvc" "$n8n_route" "$n8n_grant" "$n8n_monitor" \
  "$n8n_policy"; do
  [[ -f "$file" ]] || { echo "Missing n8n chart source: $file" >&2; exit 1; }
done
for file in "$monitoring_alerts_kustomization" "$n8n_alerts" "$n8n_alert_activation_lib" \
  "$gatus_kustomization" \
  "$gatus_values" "$gatus_canary_activation" "$prometheus_config" "$n8n_dashboard"; do
  [[ -f "$file" ]] || { echo "Missing n8n observability source: $file" >&2; exit 1; }
done
for file in "$n8n_verifier" "$n8n_verification_lib" "$n8n_verification_contract_test" \
  "$n8n_persistence" "$n8n_restore_drill" "$n8n_smoke" \
  "$n8n_operations" "$n8n_recovery" "$catalog" "$bootstrap_just" \
  "$kubernetes_just"; do
  [[ -f "$file" ]] || { echo "Missing n8n operations source: $file" >&2; exit 1; }
done

# Validate the executable public interfaces rather than inferring them from prose.
just --dry-run kube n8n-verify >"$temp_dir/n8n-verify-command" 2>&1
just --dry-run kube n8n-restore-drill >"$temp_dir/n8n-restore-command" 2>&1
just --dry-run test smoke platform n8n >"$temp_dir/n8n-smoke-command" 2>&1
just --dry-run test resilience n8n-persistence >"$temp_dir/n8n-persistence-command" 2>&1
rg -Fq 'run-catalog-suite.sh verification.n8n -- scripts/verify/n8n.sh' \
  "$temp_dir/n8n-verify-command"
rg -Fq 'run-catalog-suite.sh test.n8n-restore-drill -- scripts/test/scenarios/n8n-restore-drill.sh' \
  "$temp_dir/n8n-restore-command"
rg -Fq "run-live-suite.sh smoke 'platform' 'n8n'" "$temp_dir/n8n-smoke-command"
rg -Fq "run-live-suite.sh resilience 'n8n-persistence'" \
  "$temp_dir/n8n-persistence-command"

# Public containment removes the selected HTTPRoute while the Flux child remains
# reconciling with prune enabled. Prove that the documented empty source is a valid,
# empty Kustomize build without modifying the checked-in activation source.
mkdir -p "$temp_dir/public-route-disabled"
cp "$public_base/route/kustomization.yaml" "$public_route" \
  "$temp_dir/public-route-disabled/"
yq -i '.resources = []' "$temp_dir/public-route-disabled/kustomization.yaml"
kustomize build "$temp_dir/public-route-disabled" \
  >"$temp_dir/public-route-disabled.yaml"
[[ ! -s "$temp_dir/public-route-disabled.yaml" ]] || {
  echo 'The Git-owned public route containment source does not build empty.' >&2
  exit 1
}

# Validate executable Markdown command blocks as shell and inspect the actual curl
# option/config contracts. Human explanatory prose is deliberately not an oracle.
python - "$n8n_operations" <<'PY'
import re
import shlex
import subprocess
import sys
from pathlib import Path

document = Path(sys.argv[1]).read_text(encoding="utf-8")
fenced_blocks = re.findall(r"```(bash|zsh)\n(.*?)\n```", document, re.DOTALL)
blocks = [block for _, block in fenced_blocks]
if not blocks:
    raise SystemExit("The n8n operations guide has no executable shell command blocks.")
for index, block in enumerate(blocks, start=1):
    for shell in ("zsh", "bash"):
        syntax = subprocess.run(
            [shell, "-n"], input=block, text=True, capture_output=True, check=False
        )
        if syntax.returncode:
            raise SystemExit(
                f"The n8n operations block {index} is not valid {shell} syntax."
            )
    for line in block.splitlines():
        read_match = re.match(r"\s*(?:IFS=\s*)?read\s+(.*)", line)
        if not read_match:
            continue
        for token in shlex.split(read_match.group(1), posix=True):
            if token == "--":
                break
            if (
                token.startswith("-")
                and not token.startswith("--")
                and "p" in token[1:]
            ):
                raise SystemExit(
                    f"The n8n operations block {index} uses the incompatible read -p option."
                )
    if re.search(r"\bfor\s+path\s+in\b", block):
        raise SystemExit(
            f"The n8n operations block {index} overwrites zsh's special path array."
        )

section_match = re.search(
    r"## Off-network acceptance\n(.*?)(?=\n## )", document, re.DOTALL
)
off_network_section = section_match.group(1) if section_match else ""
off_network = next((block for block in blocks if "n8n-off-network" in block), "")
normalized = off_network_section.replace("\\\n", " ")
direct_curls = [line for line in normalized.splitlines() if "curl --silent" in line]
config_contract = {
    "umask 077",
    "mktemp -d",
    "trap cleanup_check_dir EXIT",
    "trap 'exit 130' INT",
    "trap 'exit 143' TERM",
    "rm -rf -- \"$check_dir\"",
    "connect-timeout = 10",
    "max-time = 30",
}
if (
    not off_network
    or not all(marker in off_network for marker in config_contract)
    or not direct_curls
    or any(
        "--connect-timeout" not in command or "--max-time" not in command
        for command in direct_curls
    )
):
    raise SystemExit(
        "The off-network n8n curl commands lack bounded requests or trap-backed restricted cleanup."
    )
PY

# Both mutating scenario implementations must reject an absent confirmation before
# trying to inspect kubeconfig or contact Kubernetes.
if env -u CLUSTER_CHAOS_CONFIRM -u N8N_CANARY_TOKEN \
  "$n8n_persistence" "$temp_dir/missing-kubeconfig" \
  >"$temp_dir/persistence-guard" 2>&1; then
  echo 'n8n persistence ran without its exact confirmation.' >&2
  exit 1
fi
rg -Fq 'CLUSTER_CHAOS_CONFIRM=chaos:n8n-persistence' \
  "$temp_dir/persistence-guard"
if env -u N8N_RESTORE_DRILL_CONFIRM \
  "$n8n_restore_drill" "$temp_dir/missing-kubeconfig" \
  >"$temp_dir/restore-guard" 2>&1; then
  echo 'n8n restore drill ran without its exact confirmation.' >&2
  exit 1
fi
rg -Fq 'N8N_RESTORE_DRILL_CONFIRM=restore:n8n-postgresql:temporary' \
  "$temp_dir/restore-guard"

# Catalog ownership, confirmation, dispatch, and campaign order are a stable public
# interface. These assertions operate on parsed YAML and the validator independently
# enforces command safety, access tiers, and exact-order constants.
[[ "$(yq -r '.suites[] | select(.metadata.id == "verification.n8n") |
    [.metadata.execution_owner, .metadata.mutates_cluster, .access.tier,
     .confirmation.type, .runner.command, .runner.implementation] | join(",")' "$catalog")" == \
    'human,false,observer,none,mise exec -- just kube n8n-verify,scripts/verify/n8n.sh' && \
  "$(yq -r '.suites[] | select(.metadata.id == "chainsaw.smoke.platform.n8n") |
    [.metadata.execution_owner, .metadata.mutates_cluster, .metadata.target,
     .metadata.scenario, .dispatch.mode, .dispatch.path, .dispatch.selector] | join(",")' \
    "$catalog")" == \
    'human,false,platform,n8n,chainsaw,tests/chainsaw/smoke/platform/n8n,homelab-talos/suite=platform' && \
  "$(yq -r '.suites[] | select(.metadata.id == "test.n8n-persistence") |
    [.metadata.execution_owner, .metadata.mutates_cluster, .metadata.tier,
     .confirmation.type, .confirmation.variable, .confirmation.expected,
     .dispatch.mode, .dispatch.runtime, .dispatch.path] | join(",")' "$catalog")" == \
    'human,true,resilience,exact,CLUSTER_CHAOS_CONFIRM,chaos:n8n-persistence,direct,bash,scripts/test/scenarios/n8n-persistence.sh' && \
  "$(yq -r '.suites[] | select(.metadata.id == "test.n8n-persistence") | .runner.command' \
    "$catalog")" == \
    'CLUSTER_CHAOS_CONFIRM=chaos:n8n-persistence mise exec -- just test resilience n8n-persistence' && \
  "$(yq -r '.suites[] | select(.metadata.id == "test.n8n-restore-drill") |
    [.metadata.execution_owner, .metadata.mutates_cluster, .metadata.tier,
     .confirmation.type, .confirmation.variable, .confirmation.expected,
     .dispatch.mode, .dispatch.runtime, .dispatch.path] | join(",")' "$catalog")" == \
    'human,true,integration,exact,N8N_RESTORE_DRILL_CONFIRM,restore:n8n-postgresql:temporary,direct,bash,scripts/test/scenarios/n8n-restore-drill.sh' ]] || {
  echo 'n8n catalog ownership, confirmation, access, or dispatch differs from the contract.' >&2
  exit 1
}
[[ "$(yq -r '.campaigns.integration.members | join(",")' "$catalog")" == \
    'test.cilium-connectivity,test.storage-provisioning,test.flux-canary,test.n8n-restore-drill,test.integration.media-hardlink,test.plex-network-policy,test.ntfy-publish' && \
  "$(yq -r '.campaigns.resilience.members | join(",")' "$catalog")" == \
    'test.flux-restart,test.portainer-persistence,test.n8n-persistence,chainsaw.resilience.qbittorrent-vpn-disconnect,chainsaw.resilience.qbittorrent-pod-recreation,chainsaw.resilience.plex-cross-node-reschedule,chainsaw.resilience.test-reports-persistence,chainsaw.resilience.tailscale-subnet-router-replica-recovery,test.resilience.plex-node-reboot' && \
  "$(yq -r '[.campaigns.verification.members[] | select(. == "verification.n8n")] | length' \
    "$catalog")" == '1' && \
  "$(yq -r '[.campaigns."scoped-verification".members[] | select(. == "verification.n8n")] | length' \
    "$catalog")" == '1' && \
  "$(yq -r '[.campaigns.smoke.coverage[] | select(. == "chainsaw.smoke.platform.n8n")] | length' \
    "$catalog")" == '1' ]] || {
  echo 'n8n catalog campaign membership or ordering differs from the contract.' >&2
  exit 1
}

# The read-only verifier and smoke source contain no Kubernetes Secret reads,
# database clients, exec actions, or Chainsaw mutation/script operations.
if rg -n '\b(psql|pg_dump|pg_restore)\b|kubectl[^\n]*(exec|secrets?)|curl[^\n]*(--request|-X|--data|--form)' \
  "$n8n_verifier"; then
  echo 'The read-only n8n verifier accesses a database, Secret, pod shell, or mutating HTTP method.' >&2
  exit 1
fi
# shellcheck disable=SC2016 # These are literal verifier source markers.
for marker in \
  'n8n_postgresql_backup_last_success_timestamp_seconds{namespace="automation",service="n8n-postgresql"}' \
  'for _attempt in {1..18}' \
  '($value >= (now | to_unix) - 129600 and $value <= (now | to_unix))'; do
  rg -Fq -- "$marker" "$n8n_verifier" || {
    echo "n8n verifier backup-freshness invariant is absent: $marker" >&2
    exit 1
  }
done
[[ "$(yq -r '[.. | select(type == "!!map") | select(
    .kind == "Secret" or has("script") or has("command") or has("apply") or
    has("create") or has("delete") or has("patch")
  )] | length' "$n8n_smoke")" == '0' ]] || {
  echo 'The n8n Chainsaw smoke must contain only read-only resource assertions.' >&2
  exit 1
}
[[ "$(yq -r '[.spec.steps[].try[].assert.resource |
    select(.kind == "Kustomization") |
    select(.spec.suspend == false and
      has("(metadata.generation == status.observedGeneration)") and
      has("([metadata.generation] == status.conditions[?type == '\''Ready'\''].observedGeneration)"))] | length' \
    "$n8n_smoke")" == '4' ]] || {
  echo 'The n8n Chainsaw smoke must reject suspended or stale Kustomizations.' >&2
  exit 1
}
[[ "$(yq -r '[.spec.steps[].try[].assert.resource |
    select(.kind == "HelmRelease") |
    select(.spec.suspend == false and
      has("(metadata.generation == status.observedGeneration)") and
      has("([metadata.generation] == status.conditions[?type == '\''Ready'\''].observedGeneration)"))] | length' \
    "$n8n_smoke")" == '1' ]] || {
  echo 'The n8n Chainsaw smoke must reject a suspended or stale HelmRelease.' >&2
  exit 1
}

bash "$n8n_verification_contract_test" >/dev/null || {
  echo 'The n8n verification semantic API fixtures failed.' >&2
  exit 1
}

# Inspect the parsed Just recipe source and require its safety state transitions in
# order. The public route is never resumed or reconciled by this recipe.
just --show bootstrap n8n >"$temp_dir/bootstrap-n8n-source"
bootstrap_source="$temp_dir/bootstrap-n8n-source"
# shellcheck disable=SC2016 # These are literal markers from the rendered recipe.
for marker in \
  "expected_confirmation='bootstrap:n8n'" \
  "require_deployed_source 'n8n bootstrap'" \
  'git cat-file -e "origin/main:$secret"' \
  'trap cleanup_n8n_bootstrap EXIT' \
  'flux reconcile kustomization public-webhook-gateway' \
  'flux resume kustomization n8n-postgresql' \
  'flux resume kustomization n8n --namespace flux-system' \
  'create job "$backup_job"' \
  '--from=cronjob/n8n-postgresql-backup' \
  'wait_for_backup_job "$backup_job"' \
  'N8N_VERIFY_MODE=private just kube n8n-verify' \
  'bootstrap_complete=true'; do
  rg -Fq -- "$marker" "$bootstrap_source" || {
    echo "n8n bootstrap safety marker is absent: $marker" >&2
    exit 1
  }
done
previous_line=0
# shellcheck disable=SC2016 # These are literal markers from the rendered recipe.
for marker in \
  'trap cleanup_n8n_bootstrap EXIT' \
  "require_deployed_source 'n8n bootstrap'" \
  'git cat-file -e "origin/main:$secret"' \
  '[[ "${N8N_BOOTSTRAP_CONFIRM:-}" == "$expected_confirmation" ]]' \
  'flux reconcile kustomization public-webhook-gateway' \
  'flux resume kustomization n8n-postgresql' \
  'flux resume kustomization n8n --namespace flux-system' \
  'create job "$backup_job"' \
  '--from=cronjob/n8n-postgresql-backup' \
  'wait_for_backup_job "$backup_job"' \
  'N8N_VERIFY_MODE=private just kube n8n-verify' \
  'bootstrap_complete=true'; do
  marker_line="$(rg -n -m 1 -F -- "$marker" "$bootstrap_source" | cut -d: -f1)"
  [[ -n "$marker_line" && "$marker_line" -gt "$previous_line" ]] || {
    echo "n8n bootstrap safety ordering is incorrect at: $marker" >&2
    exit 1
  }
  previous_line="$marker_line"
done
private_verify_line="$(rg -n -m 1 -F -- 'N8N_VERIFY_MODE=private just kube n8n-verify' \
  "$bootstrap_source" | cut -d: -f1)"
bootstrap_complete_line="$(rg -n -m 1 -F -- 'bootstrap_complete=true' \
  "$bootstrap_source" | cut -d: -f1)"
trap_clear_line="$(rg -n -F -- 'trap - EXIT' "$bootstrap_source" | tail -n 1 | cut -d: -f1)"
[[ -n "$private_verify_line" && -n "$bootstrap_complete_line" && -n "$trap_clear_line" && \
  "$private_verify_line" -lt "$bootstrap_complete_line" && \
  "$bootstrap_complete_line" -lt "$trap_clear_line" ]] || {
  echo 'n8n bootstrap clears its rollback trap before private verification completes.' >&2
  exit 1
}
cleanup_backup_delete_line="$(rg -n -m 1 -F -- 'delete job "$backup_job"' \
  "$bootstrap_source" | cut -d: -f1)"
cleanup_suspend_n8n_line="$(rg -n -m 1 -F -- 'flux suspend kustomization n8n --namespace' \
  "$bootstrap_source" | cut -d: -f1)"
cleanup_suspend_postgresql_line="$(rg -n -m 1 -F -- \
  'flux suspend kustomization n8n-postgresql --namespace' "$bootstrap_source" | cut -d: -f1)"
normal_backup_delete_line="$(rg -n -F -- 'delete job "$backup_job"' \
  "$bootstrap_source" | tail -n 1 | cut -d: -f1)"
backup_wait_line="$(rg -n -m 1 -F -- 'wait_for_backup_job "$backup_job"' \
  "$bootstrap_source" | cut -d: -f1)"
[[ -n "$cleanup_backup_delete_line" && -n "$cleanup_suspend_n8n_line" && \
  -n "$cleanup_suspend_postgresql_line" && -n "$normal_backup_delete_line" && \
  -n "$backup_wait_line" && \
  "$cleanup_backup_delete_line" -lt "$cleanup_suspend_n8n_line" && \
  "$cleanup_suspend_n8n_line" -lt "$cleanup_suspend_postgresql_line" && \
  "$backup_wait_line" -lt "$normal_backup_delete_line" && \
  "$normal_backup_delete_line" -lt "$private_verify_line" ]] || {
  echo 'n8n bootstrap backup cleanup, terminal wait, or rollback ordering is incorrect.' >&2
  exit 1
}
if rg -n 'resume kustomization public-webhook-route|reconcile kustomization public-webhook-route|kubectl[^\n]*(secrets?|exec)|sops[[:space:]]+-d|kubectl[^\n]*(create|patch|annotate)[^\n]*cronjob' \
  "$bootstrap_source"; then
  echo 'n8n bootstrap contains a forbidden public-route, Secret, exec, decrypt, or CronJob mutation.' >&2
  exit 1
fi
# shellcheck disable=SC2016 # These are literal markers from the rendered recipe.
for marker in 'bootstrap_run_id="$(date -u +%Y%m%d%H%M%S)-$$"' \
  'backup_job="n8n-backup-bootstrap-$bootstrap_run_id"' \
  '"homelab-talos/test" = "n8n-bootstrap"' \
  '"homelab-talos/run-id" = strenv(BOOTSTRAP_RUN_ID)' \
  '"homelab-talos/role" = "initial-backup"' \
  'local deadline=$((SECONDS + 1800)) state' \
  '.type == "Complete" and .status == "True"' \
  '.type == "Failed" and .status == "True"' \
  '--tail=80 --limit-bytes=16384 --timestamps=true' \
  'backup_job_created=true' 'delete job "$backup_job"' \
  'get job "$backup_job" --ignore-not-found --output name' \
  'backup_job_created=false'; do
  rg -Fq -- "$marker" "$bootstrap_source" || {
    echo "n8n bootstrap backup cleanup invariant is absent: $marker" >&2
    exit 1
  }
done

# The restore source must pass credentials only through secretKeyRef, select and
# checksum archives newest-first before pg_restore, omit HTTPRoute creation, and
# retain explicit cleanup verification. Persistence helpers are restricted to the
# single run-specific sentinel path.
[[ "$(rg -c 'secretKeyRef' "$n8n_restore_drill")" -ge 3 ]]
if rg -n 'kubectl[^\n]*(get|describe)[^\n]*secrets?|"kind": "HTTPRoute"|kubectl[^\n]*exec' \
  "$n8n_restore_drill" "$n8n_persistence"; then
  echo 'An n8n recovery scenario reads Secrets, creates an HTTPRoute, or uses exec.' >&2
  exit 1
fi
# shellcheck disable=SC2016 # These are literal recovery-source markers.
for marker in 'LC_ALL=C sort -r' 'sha256sum --check' 'pg_restore --list' \
  'pg_restore --dbname=' 'credentialDecryptionProvedByAuthenticatedCanary' \
  'dropdb --if-exists --force' 'write_phase cleanup failed' \
  'automation_policy="$resource_prefix-automation"' \
  'request_policy="$resource_prefix-request"' \
  'policy_manifest | "${k_cluster[@]}" create --filename -' \
  'n8n_routes_target_service automation "$service"' \
  'request_resource_absent "ciliumnetworkpolicy/$request_policy"' \
  'automation_resource_absent "$target"'; do
  rg -Fq "$marker" "$n8n_restore_drill" || {
    echo "n8n restore safety invariant is absent: $marker" >&2
    exit 1
  }
done
if rg -n 'SELECT[[:space:]]+([^;]*\.)?data\b|credential\.data' "$n8n_restore_drill"; then
  echo 'The n8n restore drill selects credential ciphertext.' >&2
  exit 1
fi
[[ "$(rg -Fc 'n8n_routes_target_service automation "$service"' \
    "$n8n_restore_drill")" == '2' ]] || {
  echo 'The n8n restore drill must perform both default-aware no-route checks.' >&2
  exit 1
}
for marker in 'sentinel="/data/.homelab-n8n-persistence-' \
  'persistentVolumeClaim": {"claimName": "n8n-data"}' \
  'verify_test_lease_holder' 'write_phase cleanup failed' \
  'write_phase recovery failed'; do
  rg -Fq "$marker" "$n8n_persistence" || {
    echo "n8n persistence safety invariant is absent: $marker" >&2
    exit 1
  }
done
[[ "$(rg -c '^backup_freshness_check$' "$n8n_persistence")" == '3' ]] || {
  echo 'n8n persistence must prove backup freshness before disruption and after both recoveries.' >&2
  exit 1
}

bash -n "$n8n_verifier" "$n8n_verification_lib" "$n8n_verification_contract_test" \
  "$n8n_persistence" "$n8n_restore_drill"
shellcheck --external-sources "$n8n_verifier" "$n8n_verification_lib" \
  "$n8n_verification_contract_test" "$n8n_persistence" "$n8n_restore_drill"
for file in "$n8n_verifier" "$n8n_verification_contract_test" "$n8n_persistence" \
  "$n8n_restore_drill"; do
  [[ -x "$file" ]] || { echo "n8n operations script is not executable: $file" >&2; exit 1; }
done

# Render every helper resource without executing either scenario. This catches yq,
# quoting, document-boundary, schema, secret-reference, and exact-volume regressions.
sed -n '/^job_manifest()/,/^}/p' "$n8n_persistence" \
  >"$temp_dir/persistence-manifest-function.sh"
(
  # shellcheck disable=SC1091 # Generated from the named function in validated source.
  source "$temp_dir/persistence-manifest-function.sh"
  run_hash='0123456789ab'
  # shellcheck disable=SC2034 # Consumed by the dynamically extracted function.
  sentinel='/data/.homelab-n8n-persistence-0123456789ab' sentinel_value='homelab-n8n-persistence-0123456789ab'
  job_manifest n8n-persistence-0123456789ab-write nuc1 write \
    >"$temp_dir/persistence-write.yaml"
  job_manifest n8n-persistence-0123456789ab-verify nuc2 verify-remove \
    >"$temp_dir/persistence-verify.yaml"
  job_manifest n8n-persistence-0123456789ab-cleanup nuc3 cleanup \
    >"$temp_dir/persistence-cleanup.yaml"
)
sed -n '/^policy_manifest()/,/^}/p; /^database_job_manifest()/,/^}/p; /^application_manifests()/,/^}/p; /^request_job_manifest()/,/^}/p' \
  "$n8n_restore_drill" >"$temp_dir/restore-manifest-functions.sh"
(
  # shellcheck disable=SC1091 # Generated from named functions in validated source.
  source "$temp_dir/restore-manifest-functions.sh"
  deployment='n8n-restore-0123456789ab'
  # shellcheck disable=SC2034 # Consumed by the dynamically extracted functions.
  automation_policy='n8n-restore-0123456789ab-automation' \
    request_policy='n8n-restore-0123456789ab-request' run_hash='0123456789ab' \
    database_name='n8n_restore_0123456789ab' service="$deployment" \
    request_job='n8n-restore-0123456789ab-request' \
    restore_job='n8n-restore-0123456789ab-load'
  policy_manifest >"$temp_dir/restore-policy.yaml"
  database_job_manifest "$restore_job" restore >"$temp_dir/restore-job.yaml"
  database_job_manifest n8n-restore-0123456789ab-drop drop \
    >"$temp_dir/restore-drop-job.yaml"
  application_manifests >"$temp_dir/restore-application.yaml"
  request_job_manifest >"$temp_dir/restore-request-job.yaml"
)
kubeconform -strict -summary -ignore-missing-schemas \
  "$temp_dir/persistence-write.yaml" "$temp_dir/persistence-verify.yaml" \
  "$temp_dir/persistence-cleanup.yaml" "$temp_dir/restore-policy.yaml" \
  "$temp_dir/restore-job.yaml" "$temp_dir/restore-drop-job.yaml" \
  "$temp_dir/restore-application.yaml" "$temp_dir/restore-request-job.yaml"
rg -Fq 'SELECT count(*) FROM pg_database WHERE datname = current_setting' \
  "$temp_dir/restore-drop-job.yaml" || {
  echo 'Rendered n8n restore cleanup does not prove temporary database absence through the catalog.' >&2
  exit 1
}
# shellcheck disable=SC2016 # These are exact commands rendered into the helper Jobs.
[[ "$(yq -r '.spec.template.spec.volumes[0].persistentVolumeClaim.claimName' \
    "$temp_dir/persistence-write.yaml")" == 'n8n-data' && \
  "$(yq -r '.spec.template.spec.containers[0].args[0]' \
    "$temp_dir/persistence-write.yaml")" == \
    'umask 077; printf %s "$SENTINEL_VALUE" >"$SENTINEL"; sync; test "$(cat "$SENTINEL")" = "$SENTINEL_VALUE"' && \
  "$(yq -r '.spec.template.spec.containers[0].args[0]' \
    "$temp_dir/persistence-verify.yaml")" == \
    'test "$(cat "$SENTINEL")" = "$SENTINEL_VALUE"; rm -f -- "$SENTINEL"; test ! -e "$SENTINEL"' && \
  "$(yq -r '.spec.template.spec.containers[0].args[0]' \
    "$temp_dir/persistence-cleanup.yaml")" == \
    'rm -f -- "$SENTINEL"; test ! -e "$SENTINEL"' ]] || {
  echo 'Rendered n8n persistence Jobs do not restrict access to the exact sentinel.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "CiliumNetworkPolicy") |
      .metadata.namespace + "/" + .metadata.name] | sort | join(",")' \
    "$temp_dir/restore-policy.yaml")" == \
    'automation/n8n-restore-0123456789ab-automation,gatus/n8n-restore-0123456789ab-request' && \
  "$(yq ea -r 'select(.metadata.namespace == "automation") | .specs | length' \
    "$temp_dir/restore-policy.yaml")" == '3' && \
  "$(yq -r '.spec.template.spec.containers[0].env[] |
    select(.name == "PGPASSWORD") | .valueFrom.secretKeyRef | [.name, .key] | join(",")' \
    "$temp_dir/restore-job.yaml")" == \
    'postgresql-credentials,postgres-superuser-password' && \
  "$(yq ea -r 'select(.kind == "Deployment") |
    [.spec.template.spec.containers[0].env[] |
      select(.name == "DB_POSTGRESDB_PASSWORD" or .name == "N8N_ENCRYPTION_KEY") |
      .name + "=" + .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key] |
    sort | join(",")' "$temp_dir/restore-application.yaml")" == \
    'DB_POSTGRESDB_PASSWORD=postgresql-credentials/n8n-password,N8N_ENCRYPTION_KEY=n8n-runtime/N8N_ENCRYPTION_KEY' && \
  "$(yq ea -r 'select(.kind == "Deployment") |
    [.spec.template.spec.containers[0].env[] |
      select(.name == "N8N_WEBHOOK_URL") | .value] | join(",")' \
    "$temp_dir/restore-application.yaml")" == \
    'http://n8n-restore-0123456789ab.automation.svc.cluster.local:5678/' && \
  "$(yq ea -r 'select(.kind == "Deployment") |
    [.spec.template.spec.containers[0].env[] | select(.name == "WEBHOOK_URL")] | length' \
    "$temp_dir/restore-application.yaml")" == '0' && \
  "$(yq -r '.spec.template.spec.containers[0].env[] |
    select(.name == "CANARY_TOKEN") | .valueFrom.secretKeyRef | [.name, .key] | join(",")' \
    "$temp_dir/restore-request-job.yaml")" == 'n8n-canary,token' && \
  -z "$(yq ea -r 'select(.kind == "HTTPRoute") | .metadata.name' \
    "$temp_dir/restore-application.yaml")" ]] || {
  echo 'Rendered n8n restore resources violate the policy, Secret, or no-route contract.' >&2
  exit 1
}
expected_request_egress='[{"toEndpoints":["homelab-talos/role=n8n,homelab-talos/run-id=0123456789ab,homelab-talos/test=n8n-restore-drill,k8s:io.kubernetes.pod.namespace=automation"],"toPorts":["5678/TCP"]},{"toEndpoints":["k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns"],"toPorts":["53/TCP","53/UDP"]}]'
actual_request_egress="$(yq ea -o=json -I=0 '
  select(.metadata.namespace == "gatus") | [.spec.egress[] | {
    "toEndpoints": ([.toEndpoints[].matchLabels | to_entries | sort_by(.key) |
      map(.key + "=" + .value) | join(",")] | sort),
    "toPorts": ([.toPorts[].ports[] | .port + "/" + .protocol] | sort)
  }] | sort_by((.toEndpoints + .toPorts) | join("|"))
' "$temp_dir/restore-policy.yaml")"
[[ "$(yq ea -o=json -I=0 'select(.metadata.namespace == "gatus") |
    .spec.endpointSelector.matchLabels' "$temp_dir/restore-policy.yaml")" == \
    '{"homelab-talos/test":"n8n-restore-drill","homelab-talos/run-id":"0123456789ab","homelab-talos/role":"request"}' && \
  "$(yq ea -r 'select(.metadata.namespace == "gatus") | .spec.ingress | length' \
    "$temp_dir/restore-policy.yaml")" == '0' && \
  "$actual_request_egress" == "$expected_request_egress" ]] || {
  echo 'Rendered n8n restore request policy must select only its Job and allow only DNS and its temporary n8n endpoint.' >&2
  exit 1
}
restore_command="$(yq -r '.spec.template.spec.containers[0].args[0]' \
  "$temp_dir/restore-job.yaml")"
request_command="$(yq -r '.spec.template.spec.containers[0].args[0]' \
  "$temp_dir/restore-request-job.yaml")"
[[ "$restore_command" == *'count(*) = 1'* && \
  "$restore_command" == *'Platform Canary Header'* && \
  "$restore_command" == *'httpHeaderAuth'* && \
  "$restore_command" == *'jsonb_array_elements(workflow.nodes::jsonb)'* && \
  "$restore_command" != *'credential.data'* && \
  "$restore_command" != *'SELECT data'* && \
  "$(yq -r '.spec.template.spec.containers[0].command | join(",")' \
    "$temp_dir/restore-request-job.yaml")" == 'node,--input-type=module,--eval' && \
  "$request_command" == *'const negative = await send'* && \
  "$request_command" == *'[400, 401, 403, 404]'* && \
  "$request_command" == *'Object.keys(body).sort()'* && \
  "$request_command" == *'["correlation", "executionId", "status"]'* && \
  "$request_command" == *'body.executionId.length === 0'* ]] || {
  echo 'Rendered n8n restore proof must bind exact metadata and structurally validate negative and authenticated canary responses.' >&2
  exit 1
}
[[ -f "$n8n_workflow" ]] || {
  echo "Missing n8n Platform Canary workflow template: $n8n_workflow" >&2
  exit 1
}
yq -e '.resources[] | select(. == "./automation")' kubernetes/apps/kustomization.yaml >/dev/null
yq -e '.resources[] | select(. == "./public-webhook-gateway/ks.yaml")' \
  kubernetes/apps/networking/kustomization.yaml >/dev/null
[[ "$(yq -r '.metadata.name' "$ns")" == 'automation' ]]
[[ "$(yq -r '.metadata.labels."gateway.supermorphic.com/access"' "$ns")" == 'internal' ]] || {
  echo 'n8n automation namespace Gateway access must be internal.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.labels."pod-security.kubernetes.io/enforce"' "$ns")" == 'restricted' ]]
[[ "$(yq -r '.spec.dependsOn[0].name' "$base/namespace/ks.yaml")" == 'cilium' ]]
kustomize build "$base/namespace/app" >/dev/null

validate_selected_sops_secret \
  "$base/n8n/app/kustomization.yaml" './n8n-runtime.sops.yaml' \
  "$base/n8n/app/n8n-runtime.sops.yaml" n8n-runtime automation \
  'N8N_ENCRYPTION_KEY,N8N_HOST,N8N_PORT,N8N_PROTOCOL'
validate_selected_sops_secret \
  "$base/n8n-postgresql/app/kustomization.yaml" './postgresql-credentials.sops.yaml' \
  "$base/n8n-postgresql/app/postgresql-credentials.sops.yaml" postgresql-credentials automation \
  'backup-password,exporter-dsn,exporter-password,n8n-password,postgres-superuser-password'
validate_selected_sops_secret \
  'kubernetes/apps/monitoring/gatus/app/kustomization.yaml' './n8n-canary.sops.yaml' \
  'kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml' n8n-canary gatus token

yq -e '(.metadata.name == "networking-public") and
  (.metadata.labels | length == 1) and
  (.metadata.labels."gateway.supermorphic.com/access" == "public")' "$public_namespace" >/dev/null || {
  echo 'networking-public must have only the public Gateway access label.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks")] | length' "$public_pool")" == '1' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.addresses | length' "$public_pool")" == '1' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.addresses[0]' "$public_pool")" == '192.168.90.39/32' && \
  "$(yq ea -r 'select(.kind == "IPAddressPool" and .metadata.name == "public-webhooks") | .spec.autoAssign' "$public_pool")" == 'false' ]] || {
  echo 'public-webhooks must contain only 192.168.90.39/32 with autoAssign=false.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$public_certificate")" == 'hooks-lab-supermorphic-com' && \
  "$(yq -r '.spec.dnsNames | length' "$public_certificate")" == '1' && \
  "$(yq -r '.spec.dnsNames[0]' "$public_certificate")" == 'hooks.lab.supermorphic.com' && \
  "$(yq -r '.spec.issuerRef.name' "$public_certificate")" == 'letsencrypt-production' && \
  "$(yq -r '.spec.privateKey.algorithm' "$public_certificate")" == 'ECDSA' ]] || {
  echo 'The public Certificate must contain only hooks.lab.supermorphic.com.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "GatewayClass" and .metadata.name == "public-webhooks")] | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "GatewayClass" and .metadata.name == "public-webhooks") | .spec.controllerName' "$public_gateway")" == 'gateway.envoyproxy.io/gatewayclass-controller' ]] || {
  echo 'The public GatewayClass must use the Envoy Gateway controller.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks")] | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.gatewayClassName' "$public_gateway")" == 'public-webhooks' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners | length' "$public_gateway")" == '1' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners[0].hostname' "$public_gateway")" == 'hooks.lab.supermorphic.com' && \
  "$(yq ea -r 'select(.kind == "Gateway" and .metadata.namespace == "networking-public" and .metadata.name == "public-webhooks") | .spec.listeners[0].allowedRoutes.namespaces.from' "$public_gateway")" == 'Same' ]] || {
  echo 'The public listener must use its exact hostname and Same-namespace route admission.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | [.spec.dependsOn[].name] | sort | join(",")' "$public_ks")" == 'n8n,public-webhook-gateway' && \
  "$(yq ea -r 'select(.metadata.name == "public-webhook-route") | .spec.suspend' "$public_ks")" == 'true' ]] || {
  echo 'The public webhook route must depend on public-webhook-gateway and n8n while suspended.' >&2
  exit 1
}
[[ "$(yq -r '.resources | join(",")' "$public_base/route/kustomization.yaml")" == \
    './httproute.yaml' && \
  "$(yq -r '.metadata.namespace' "$public_route")" == 'networking-public' && \
  "$(yq -r '.spec | keys | sort | join(",")' "$public_route")" == \
    'hostnames,parentRefs,rules' && \
  "$(yq -r '.spec.parentRefs | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.parentRefs[0] | [.group, .kind, .namespace, .name, .sectionName] | join(",")' "$public_route")" == 'gateway.networking.k8s.io,Gateway,networking-public,public-webhooks,https' && \
  "$(yq -r '.spec.rules | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0] | keys | sort | join(",")' "$public_route")" == \
    'backendRefs,matches' && \
  "$(yq -r '.spec.rules[0].matches | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].matches[0] | keys | sort | join(",")' "$public_route")" == \
    'path' && \
  "$(yq -r '.spec.rules[0].matches[0].path | [.type, .value] | join(",")' "$public_route")" == 'Exact,/webhook/platform-canary' && \
  "$(yq -r '.spec.rules[0].backendRefs | length' "$public_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs[0] | keys | sort | join(",")' "$public_route")" == \
    'group,kind,name,namespace,port' && \
  "$(yq -r '.spec.rules[0].backendRefs[0] | [.group, .kind, .namespace, .name, .port] | join(",")' "$public_route")" == ',Service,automation,n8n,5678' ]] || {
  echo 'The public webhook route must be the exact platform-canary path to automation/n8n:5678.' >&2
  exit 1
}
[[ "$(yq -r '.annotationFilter' "$external_dns")" == 'external-dns.k8s.io/audience=internal' ]] || {
  echo 'The internal ExternalDNS controller must not publish the public webhook name.' >&2
  exit 1
}

yq -e '.resources[] | select(. == "./n8n-postgresql/ks.yaml")' \
  "$base/kustomization.yaml" >/dev/null || {
  echo 'The automation root must select n8n-postgresql/ks.yaml.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$postgresql_ks")" == 'n8n-postgresql' && \
  "$(yq -r '.metadata.namespace' "$postgresql_ks")" == 'flux-system' && \
  "$(yq -r '.spec.path' "$postgresql_ks")" == './kubernetes/apps/automation/n8n-postgresql/app' && \
  "$(yq -r '.spec.suspend' "$postgresql_ks")" == 'true' && \
  "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$postgresql_ks")" == \
    'automation,cilium,kube-prometheus-stack,longhorn' ]] || {
  echo 'n8n-postgresql must remain suspended with its complete foundation dependency graph.' >&2
  exit 1
}
declare -A postgresql_resource_counts=()
while IFS= read -r resource; do
  resource="$(normalise_resource_path "$resource")"
  case "$resource" in
    ciliumnetworkpolicy.yaml | cronjob.yaml | persistentvolumeclaims.yaml | service.yaml | \
      servicemonitor.yaml | statefulset.yaml | postgresql-credentials.sops.yaml)
      postgresql_resource_counts["$resource"]=$((
        ${postgresql_resource_counts["$resource"]:-0} + 1
      ))
      ;;
    *)
      echo "The PostgreSQL app Kustomization selects an unexpected resource: $resource" >&2
      exit 1
      ;;
  esac
done < <(yq -r '.resources[]' "$postgresql_kustomization")
for resource in ciliumnetworkpolicy.yaml cronjob.yaml persistentvolumeclaims.yaml \
  service.yaml servicemonitor.yaml statefulset.yaml; do
  [[ "${postgresql_resource_counts["$resource"]:-0}" == '1' ]] || {
    echo "The PostgreSQL app must select $resource exactly once." >&2
    exit 1
  }
done
[[ "${postgresql_resource_counts[postgresql-credentials.sops.yaml]:-0}" -le 1 ]] || {
  echo 'The PostgreSQL app must not select its credential Secret more than once.' >&2
  exit 1
}
[[ "$(yq -r '[.configMapGenerator[].name] | sort | join(",")' \
  "$postgresql_kustomization")" == \
  'n8n-postgresql-backup,n8n-postgresql-init,n8n-postgresql-sql-exporter' ]] || {
  echo 'The PostgreSQL app must render init, backup, and SQL Exporter ConfigMaps.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .metadata.name] | sort | join(",")' \
  "$postgresql_pvcs")" == 'n8n-postgresql-backups,n8n-postgresql-data' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .spec.resources.requests.storage] | unique | join(",")' \
  "$postgresql_pvcs")" == '10Gi' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .spec.accessModes[]] | unique | join(",")' \
  "$postgresql_pvcs")" == 'ReadWriteOnce' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .spec.storageClassName] | unique | join(",")' \
  "$postgresql_pvcs")" == 'longhorn' && \
  "$(yq ea -r '[select(.kind == "PersistentVolumeClaim") | .metadata.annotations."kustomize.toolkit.fluxcd.io/prune"] | unique | join(",")' \
  "$postgresql_pvcs")" == 'disabled' ]] || {
  echo 'PostgreSQL data and backup claims must be retained 10Gi Longhorn RWO claims.' >&2
  exit 1
}

[[ "$(yq -r '.spec.type' "$postgresql_service")" == 'ClusterIP' && \
  "$(yq -r '[.spec.ports[] | .name + ":" + (.port | tostring)] | sort | join(",")' \
  "$postgresql_service")" == 'metrics:9399,postgresql:5432' ]] || {
  echo 'PostgreSQL must expose only its internal database and exporter Service ports.' >&2
  exit 1
}

[[ "$(yq -r '.spec.replicas' "$postgresql_statefulset")" == '1' && \
  "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$postgresql_statefulset")" == 'false' && \
  "$(yq -r '.spec.template.spec.securityContext.seccompProfile.type' "$postgresql_statefulset")" == 'RuntimeDefault' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .image' \
  "$postgresql_statefulset")" == 'postgres:17.11-alpine3.24' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | .image' \
  "$postgresql_statefulset")" == 'burningalchemist/sql_exporter:0.24.6' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .securityContext.runAsUser' \
  "$postgresql_statefulset")" == '70' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .securityContext.runAsGroup' \
  "$postgresql_statefulset")" == '70' && \
  "$(yq -r '[.spec.template.spec.containers[].securityContext.capabilities.drop[]] | unique | join(",")' \
  "$postgresql_statefulset")" == 'ALL' ]] || {
  echo 'The PostgreSQL pod must use one hardened replica with the exact database and exporter images.' >&2
  exit 1
}
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .env[] | select(.name == "PGDATA") | .value' \
  "$postgresql_statefulset")" == '/var/lib/postgresql/data/pgdata' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | [.startupProbe.exec.command[0], .readinessProbe.exec.command[0], .livenessProbe.exec.command[0]] | unique | join(",")' \
  "$postgresql_statefulset")" == 'pg_isready' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .volumeMounts[] | select(.mountPath == "/docker-entrypoint-initdb.d") | .readOnly' \
  "$postgresql_statefulset")" == 'true' && \
  "$(yq -r '.spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName' \
  "$postgresql_statefulset")" == 'n8n-postgresql-data' ]] || {
  echo 'The PostgreSQL container must mount retained data and read-only initialization with exec probes.' >&2
  exit 1
}
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(",")' \
  "$postgresql_statefulset")" == '50m,256Mi,1Gi' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "postgresql") | .resources.limits | has("cpu") | not' \
  "$postgresql_statefulset")" == 'true' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(",")' \
  "$postgresql_statefulset")" == '10m,32Mi,128Mi' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | .resources.limits | has("cpu") | not' \
  "$postgresql_statefulset")" == 'true' ]] || {
  echo 'PostgreSQL and SQL Exporter resource envelopes do not match the capacity design.' >&2
  exit 1
}
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | .securityContext.runAsNonRoot' \
  "$postgresql_statefulset")" == 'true' && \
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "sql-exporter") | [.env[] | select(has("valueFrom")) | .valueFrom.secretKeyRef.key] | join(",")' \
  "$postgresql_statefulset")" == 'exporter-dsn' ]] || {
  echo 'SQL Exporter must run non-root and consume only exporter-dsn.' >&2
  exit 1
}

[[ "$(yq -r '.spec.schedule' "$postgresql_cronjob")" == '0 1 * * *' && \
  "$(yq -r '.spec.timeZone' "$postgresql_cronjob")" == 'Etc/UTC' && \
  "$(yq -r '.spec.concurrencyPolicy' "$postgresql_cronjob")" == 'Forbid' && \
  "$(yq -r '.spec.successfulJobsHistoryLimit' "$postgresql_cronjob")" == '1' && \
  "$(yq -r '.spec.failedJobsHistoryLimit' "$postgresql_cronjob")" == '1' && \
  "$(yq -r '.spec.jobTemplate.spec.activeDeadlineSeconds' "$postgresql_cronjob")" == '1800' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .image' \
  "$postgresql_cronjob")" == 'postgres:17.11-alpine3.24' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | [.resources.requests.cpu, .resources.requests.memory, .resources.limits.memory] | join(",")' \
  "$postgresql_cronjob")" == '50m,64Mi,512Mi' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .resources.limits | has("cpu") | not' \
  "$postgresql_cronjob")" == 'true' ]] || {
  echo 'The logical backup CronJob schedule, history, deadline, image, or resources are incorrect.' >&2
  exit 1
}
[[ "$(yq -r '.spec.jobTemplate.spec.template.metadata.labels."app.kubernetes.io/name"' \
  "$postgresql_cronjob")" == 'n8n-postgresql-backup' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.securityContext | [.runAsUser, .runAsGroup] | join(",")' \
  "$postgresql_cronjob")" == '70,70' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.securityContext.seccompProfile.type' \
  "$postgresql_cronjob")" == 'RuntimeDefault' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .securityContext.capabilities.drop | join(",")' \
  "$postgresql_cronjob")" == 'ALL' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .securityContext.readOnlyRootFilesystem' \
  "$postgresql_cronjob")" == 'true' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | [.env[] | select(has("valueFrom")) | .valueFrom.secretKeyRef.key] | join(",")' \
  "$postgresql_cronjob")" == 'backup-password' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[] | select(.name == "backup") | .volumeMounts[] | select(.mountPath == "/scripts/update-backup-status.sql") | .readOnly' \
  "$postgresql_cronjob")" == 'true' && \
  "$(yq -r '.spec.jobTemplate.spec.template.spec.volumes[] | select(.name == "backups") | .persistentVolumeClaim.claimName' \
  "$postgresql_cronjob")" == 'n8n-postgresql-backups' ]] || {
  echo 'The backup Job identity, least-privileged credential, scripts, or retained claim are incorrect.' >&2
  exit 1
}

[[ "$(yq -r '.spec.selector.matchLabels."app.kubernetes.io/name"' "$postgresql_monitor")" == \
  'n8n-postgresql' && \
  "$(yq -r '[.spec.endpoints[] | .port + ":" + .path] | join(",")' \
  "$postgresql_monitor")" == 'metrics:/metrics' ]] || {
  echo 'The PostgreSQL ServiceMonitor must scrape only the named metrics port.' >&2
  exit 1
}
validate_postgresql_metrics_ingress "$postgresql_policy"
[[ "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | [.spec.ingress[].toPorts[].ports[].port] | sort | join(",")' \
  "$postgresql_policy")" == '5432,9399' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | [.spec.ingress[] | select(.toPorts[].ports[].port == "5432") | .fromEndpoints[].matchLabels."app.kubernetes.io/name"] | sort | join(",")' \
  "$postgresql_policy")" == 'n8n,n8n-postgresql-backup' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | [.spec.ingress[].fromEndpoints[].matchLabels."k8s:io.kubernetes.pod.namespace"] | sort | join(",")' \
  "$postgresql_policy")" == 'automation,automation,monitoring' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql") | .spec.egress | length' \
  "$postgresql_policy")" == '0' ]] || {
  echo 'PostgreSQL ingress identities or no-egress containment are incorrect.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toPorts[].ports[].port] | sort | join(",")' \
  "$postgresql_policy")" == '53,53,5432' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toEndpoints[].matchLabels."app.kubernetes.io/name"] | map(select(. != null)) | join(",")' \
  "$postgresql_policy")" == 'n8n-postgresql' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "n8n-postgresql") | .matchLabels."k8s:io.kubernetes.pod.namespace"] | join(",")' \
  "$postgresql_policy")" == 'automation' && \
  "$(yq ea -r 'select(.metadata.name == "n8n-postgresql-backup") | [.spec.egress[].toEndpoints[].matchLabels."k8s:k8s-app"] | map(select(. != null)) | join(",")' \
  "$postgresql_policy")" == 'kube-dns' ]] || {
  echo 'The backup Job must reach only cluster DNS and PostgreSQL.' >&2
  exit 1
}

[[ "$(yq -r '[.collectors[].metrics[].metric_name] | sort | join(",")' \
  "$postgresql_exporter")" == \
  'n8n_postgresql_backup_last_success_timestamp_seconds,n8n_postgresql_connections,n8n_postgresql_database_size_bytes,n8n_postgresql_transactions_total' && \
  "$(yq -r '.collectors[].metrics[] | select(.metric_name == "n8n_postgresql_connections") | .key_labels | join(",")' \
  "$postgresql_exporter")" == 'state' && \
  "$(yq -r '.collectors[].metrics[] | select(.metric_name == "n8n_postgresql_transactions_total") | .key_labels | join(",")' \
  "$postgresql_exporter")" == 'result' ]] || {
  echo 'SQL Exporter must define the four n8n PostgreSQL metric families.' >&2
  exit 1
}

sh -n "$postgresql_init" "$postgresql_backup"
shellcheck "$postgresql_init" "$postgresql_backup"
kustomize build "$postgresql_app" >"$temp_dir/postgresql.yaml"
yq ea 'del(.sops)' "$temp_dir/postgresql.yaml" >"$temp_dir/postgresql-conform.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/postgresql-conform.yaml"
validate_postgresql_metrics_ingress "$temp_dir/postgresql.yaml"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."init-database.sh" != null) | .data."init-database.sh"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/init-database.sh"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."backup.sh" != null) | .data."backup.sh"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/backup.sh"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."update-backup-status.sql" != null) | .data."update-backup-status.sql"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/update-backup-status.sql"
yq ea -r 'select(.kind == "ConfigMap" and has("data") and .data."sql-exporter.yml" != null) | .data."sql-exporter.yml"' \
  "$temp_dir/postgresql.yaml" >"$temp_dir/sql-exporter.yml"
[[ -s "$temp_dir/init-database.sh" && -s "$temp_dir/backup.sh" && \
  -s "$temp_dir/update-backup-status.sql" && -s "$temp_dir/sql-exporter.yml" ]] || {
  echo 'The rendered PostgreSQL ConfigMaps must contain every runtime script and collector.' >&2
  exit 1
}
[[ "$(yq -r '[.collectors[].metrics[].metric_name] | sort | join(",")' \
  "$temp_dir/sql-exporter.yml")" == \
  'n8n_postgresql_backup_last_success_timestamp_seconds,n8n_postgresql_connections,n8n_postgresql_database_size_bytes,n8n_postgresql_transactions_total' ]]
rg -q '^CREATE ROLE n8n ' "$temp_dir/init-database.sh"
rg -q '^CREATE ROLE n8n_backup ' "$temp_dir/init-database.sh"
rg -q '^CREATE ROLE n8n_exporter ' "$temp_dir/init-database.sh"
rg -q '^GRANT pg_read_all_data TO n8n_backup;' "$temp_dir/init-database.sh"
rg -q '^GRANT pg_monitor TO n8n_exporter;' "$temp_dir/init-database.sh"
rg -q '^GRANT SELECT, INSERT, UPDATE ON platform_operations.logical_backup_status TO n8n_backup;' \
  "$temp_dir/init-database.sh"
rg -q '^GRANT SELECT ON platform_operations.logical_backup_status TO n8n_exporter;' \
  "$temp_dir/init-database.sh"
! rg -q -- '--set=.*PASSWORD' "$temp_dir/init-database.sh" || {
  echo 'Database initialization must not place role passwords in process arguments.' >&2
  exit 1
}
rg -q '^INSERT INTO platform_operations.logical_backup_status' "$temp_dir/update-backup-status.sql"
rg -q '^ON CONFLICT ' "$temp_dir/update-backup-status.sql"
rg -q '^DO UPDATE SET' "$temp_dir/update-backup-status.sql"
rg -Fq ":'completed_at'::timestamp with time zone" "$temp_dir/update-backup-status.sql"
rg -Fq ":'filename'::text" "$temp_dir/update-backup-status.sql"
rg -Fq ":'checksum'::character(64)" "$temp_dir/update-backup-status.sql"

previous_line=0
# shellcheck disable=SC2016 # These are literal markers from the rendered script.
for marker in \
  'pg_dump --format=custom --compress=9 --no-owner --no-privileges' \
  'pg_restore --file /dev/null "$temporary_dump"' \
  'checksum_line="$(sha256sum "$temporary_dump")"' \
  'checksum="${checksum_line%% *}"' \
  'printf '\''%s  %s\n'\'' "$checksum" "$(basename "$final_dump")"' \
  'mv -- "$temporary_dump" "$final_dump"' \
  'mv -- "$temporary_checksum" "$final_checksum"' \
  '(cd "$backup_dir" && sha256sum --check "$(basename "$final_checksum")")' \
  'psql --set=ON_ERROR_STOP=1 --set=completed_at="$completed_at"'; do
  marker_line="$(rg -n -m 1 -F -- "$marker" "$temp_dir/backup.sh" | cut -d: -f1)"
  [[ -n "$marker_line" && "$marker_line" -gt "$previous_line" ]] || {
    echo "Rendered backup order is missing or incorrect at: $marker" >&2
    exit 1
  }
  previous_line="$marker_line"
done
cleanup_line="$(rg -n -m 1 -F -- 'find "$backup_dir"' "$temp_dir/backup.sh" | cut -d: -f1)"
[[ -n "$cleanup_line" && "$cleanup_line" -gt "$previous_line" ]] || {
  echo 'Backup cleanup must occur only after the status upsert.' >&2
  exit 1
}

[[ -z "$(yq ea -r 'select(.kind == "HTTPRoute") | .metadata.name' \
  "$temp_dir/postgresql.yaml")" ]] || {
  echo 'PostgreSQL must not render an HTTPRoute.' >&2
  exit 1
}
[[ -z "$(yq ea -r 'select(.kind == "Service" and (.spec.type == "NodePort" or .spec.type == "LoadBalancer")) | .metadata.name' \
  "$temp_dir/postgresql.yaml")" ]] || {
  echo 'PostgreSQL must not render an externally exposed Service.' >&2
  exit 1
}

yq -e '.resources[] | select(. == "./n8n/ks.yaml")' "$base/kustomization.yaml" >/dev/null || {
  echo 'The automation root must select n8n/ks.yaml.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$n8n_ks")" == 'n8n' && \
  "$(yq -r '.metadata.namespace' "$n8n_ks")" == 'flux-system' && \
  "$(yq -r '.spec.path' "$n8n_ks")" == './kubernetes/apps/automation/n8n/app' && \
  "$(yq -r '.spec.suspend' "$n8n_ks")" == 'true' && \
  "$(yq ea -r '[.spec.dependsOn[].name] | sort | join(",")' "$n8n_ks")" == \
    'automation,cilium,internal-gateway,kube-prometheus-stack,longhorn,n8n-postgresql,public-webhook-gateway' ]] || {
  echo 'n8n must remain suspended with its complete foundation dependency graph.' >&2
  exit 1
}

[[ "$(yq -r '.kind' "$n8n_source")" == 'OCIRepository' && \
  "$(yq -r '.metadata.name' "$n8n_source")" == 'n8n-chart' && \
  "$(yq -r '.metadata.namespace' "$n8n_source")" == 'automation' && \
  "$(yq -r '.spec.url' "$n8n_source")" == 'oci://ghcr.io/n8n-io/n8n-helm-chart/n8n' && \
  "$(yq -r '.spec.ref.digest' "$n8n_source")" == \
    'sha256:a0bf4694f6e0f91dfb196fd8de08ad40cb3dd798edaa9bd54fa9c3f32566517c' && \
  "$(yq -r '.spec.layerSelector | [.mediaType, .operation] | join(",")' "$n8n_source")" == \
    'application/vnd.cncf.helm.chart.content.v1.tar+gzip,copy' ]] || {
  echo 'n8n must use the immutable official chart 1.11.0 OCI artifact.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.name' "$n8n_release")" == 'n8n' && \
  "$(yq -r '.metadata.namespace' "$n8n_release")" == 'automation' && \
  "$(yq -r '.spec.chartRef | [.kind, .name] | join(",")' "$n8n_release")" == \
    'OCIRepository,n8n-chart' && \
  "$(yq -r '.spec.releaseName' "$n8n_release")" == 'n8n' && \
  "$(yq -r '.spec.valuesFrom | length' "$n8n_release")" == '1' && \
  "$(yq -r '.spec.valuesFrom[0] | [.kind, .name, .valuesKey] | join(",")' "$n8n_release")" == \
    'ConfigMap,n8n-values,values.yaml' ]] || {
  echo 'The n8n HelmRelease must consume only the watched n8n-values ConfigMap.' >&2
  exit 1
}
expected_postrender_contract='[{"target":{"group":"apps","version":"v1","kind":"Deployment","name":"n8n-main"},"patch":[{"op":"replace","path":"/metadata/name","value":"n8n"}]},{"target":{"group":"","version":"v1","kind":"Service","name":"n8n-main"},"patch":[{"op":"replace","path":"/metadata/name","value":"n8n"}]}]'
actual_postrender_contract="$(yq -o=json -I=0 '
  [.spec.postRenderers[0].kustomize.patches[] | {
    "target": {
      "group": .target.group,
      "version": .target.version,
      "kind": .target.kind,
      "name": .target.name
    },
    "patch": (.patch | from_yaml)
  }] | sort_by(.target.kind)
' "$n8n_release")"
[[ "$(yq -r '.spec.postRenderers | length' "$n8n_release")" == '1' && \
  "$(yq -r '.spec.postRenderers[0] | keys | sort | join(",")' "$n8n_release")" == \
    'kustomize' && \
  "$(yq -r '.spec.postRenderers[0].kustomize | keys | sort | join(",")' \
    "$n8n_release")" == 'patches' && \
  "$(yq -r '[.spec.postRenderers[0].kustomize.patches[].target |
    keys | sort | join(",")] | sort | join(";")' "$n8n_release")" == \
    'group,kind,name,version;group,kind,name,version' && \
  "$actual_postrender_contract" == "$expected_postrender_contract" ]] || {
  echo 'The Helm post-renderer must expose the one main Deployment and Service as n8n.' >&2
  exit 1
}

declare -A n8n_resource_counts=()
while IFS= read -r resource; do
  resource="$(normalise_resource_path "$resource")"
  case "$resource" in
    ciliumnetworkpolicy.yaml | helmrelease.yaml | httproute.yaml | ocirepository.yaml | \
      persistentvolumeclaim.yaml | referencegrant.yaml | servicemonitor.yaml | n8n-runtime.sops.yaml)
      n8n_resource_counts["$resource"]=$((
        ${n8n_resource_counts["$resource"]:-0} + 1
      ))
      ;;
    *)
      echo "The n8n app Kustomization selects an unexpected resource: $resource" >&2
      exit 1
      ;;
  esac
done < <(yq -r '.resources[]' "$n8n_kustomization")
for resource in ciliumnetworkpolicy.yaml helmrelease.yaml httproute.yaml ocirepository.yaml \
  persistentvolumeclaim.yaml referencegrant.yaml servicemonitor.yaml; do
  [[ "${n8n_resource_counts["$resource"]:-0}" == '1' ]] || {
    echo "The n8n app must select $resource exactly once." >&2
    exit 1
  }
done
expected_n8n_configmaps='[{"files":["values.yaml=values.yaml"],"name":"n8n-values"},{"files":["platform-canary.json=workflows/platform-canary.json"],"name":"n8n-workflow-templates"}]'
actual_n8n_configmaps="$(yq -o=json -I=0 '
  [.configMapGenerator[] | {"files": .files, "name": .name}] | sort_by(.name)
' "$n8n_kustomization")"
[[ "${n8n_resource_counts[n8n-runtime.sops.yaml]:-0}" -le 1 && \
  "$actual_n8n_configmaps" == "$expected_n8n_configmaps" && \
  "$(yq -r '.generatorOptions.disableNameSuffixHash' "$n8n_kustomization")" == 'true' ]] || {
  echo 'The n8n app must package the stable values and inactive Platform Canary template ConfigMaps.' >&2
  exit 1
}

jq -e . "$n8n_workflow" >/dev/null || {
  echo 'Platform Canary must be valid importable workflow JSON.' >&2
  exit 1
}
jq -e '
  .name == "Platform Canary" and
  .active == false and
  (.nodes | type == "array" and length == 2) and
  ([.nodes[] | .type] | sort) == ["n8n-nodes-base.set", "n8n-nodes-base.webhook"] and
  ([.nodes[] | select(
    .type == "n8n-nodes-base.webhook" and
    .name == "Webhook" and
    .parameters.responseMode == "lastNode" and
    .parameters.authentication == "headerAuth"
  )] | length) == 1 and
  ([.nodes[] | select(
    .type == "n8n-nodes-base.set" and .name == "Edit Fields"
  )] | length) == 1 and
  .connections == {
    "Webhook": {
      "main": [[{"node": "Edit Fields", "type": "main", "index": 0}]]
    }
  } and
  ([.. | objects | select(has("credentials"))] | length) == 0
' "$n8n_workflow" >/dev/null || {
  echo 'Platform Canary must be a secret-free inactive two-node Webhook and Edit Fields template.' >&2
  exit 1
}
[[ "$(jq -r '[
  .nodes[] | select(.name == "Webhook" or .name == "Edit Fields") | .typeVersion
] | join(",")' "$n8n_workflow")" == '2.1,3.4' ]] || {
  echo 'Platform Canary must use the pinned Webhook 2.1 and Edit Fields 3.4 node versions.' >&2
  exit 1
}
# shellcheck disable=SC2016 # The expected n8n expressions are literal workflow JSON.
expected_canary_fields='[{"name":"correlation","type":"string","value":"={{ $json.body.correlation }}"},{"name":"executionId","type":"string","value":"={{ $execution.id }}"},{"name":"status","type":"string","value":"ok"}]'
actual_canary_fields="$(jq -c '
  [.nodes[] | select(.type == "n8n-nodes-base.set") |
    .parameters.assignments.assignments[] | {name, type, value}] | sort_by(.name)
' "$n8n_workflow")"
[[ "$actual_canary_fields" == "$expected_canary_fields" ]] || {
  echo 'Platform Canary must return only the required status, correlation, and executionId fields.' >&2
  exit 1
}
[[ "$(jq -r '[.settings.saveDataErrorExecution, .settings.saveDataSuccessExecution] | join(",")' \
  "$n8n_workflow")" == 'all,all' ]] || {
  echo 'Platform Canary must save successful and failed executions.' >&2
  exit 1
}
workflow_path="$(jq -r '.nodes[] | select(.type == "n8n-nodes-base.webhook") | .parameters.path' \
  "$n8n_workflow")"
expected_public_route_contract='{"metadata":{"name":"n8n-platform-canary","namespace":"networking-public"},"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"public-webhooks","namespace":"networking-public","sectionName":"https"}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"n8n","namespace":"automation","port":5678}],"matches":[{"path":{"type":"Exact","value":"/webhook/platform-canary"}}]}]}'
mapfile -t public_route_contracts < <(
  while IFS= read -r -d '' manifest; do
    # shellcheck disable=SC2016 # yq evaluates $route_namespace, not the shell.
    yq -o=json -I=0 '
      select(type == "!!map") |
      select(.kind == "HTTPRoute") |
      .metadata.namespace as $route_namespace |
      select([
        .spec.parentRefs[]? |
        select(.name == "public-webhooks" and
          (.namespace // $route_namespace) == "networking-public")
      ] | length > 0) |
      {
        "metadata": {"name": .metadata.name, "namespace": .metadata.namespace},
        "parentRefs": .spec.parentRefs,
        "rules": [
          .spec.rules[]? |
          {"backendRefs": (.backendRefs // []), "matches": (.matches // [])}
        ]
      }
    ' "$manifest" | jq -cS 'select(.metadata != null)'
  done < <(find kubernetes/apps -type f \
    \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print0)
)
[[ "${#public_route_contracts[@]}" == '1' && \
  "${public_route_contracts[0]}" == "$expected_public_route_contract" ]] || {
  echo 'The public Gateway must have exactly one complete Platform Canary HTTPRoute contract.' >&2
  exit 1
}
[[ "$(yq -r '.spec.rules[0].matches[0].path.value' "$public_route")" == \
  "/webhook/$workflow_path" ]] || {
  echo 'The public route and Platform Canary Webhook must use the same production path.' >&2
  exit 1
}

# Cross-component observability checks derive identities from the workload, route,
# collector, and probe sources. This prevents copied literals from agreeing with one
# another while drifting away from the resources that produce the metrics.
[[ "$(yq -r '[.configMapGenerator[] | select(.name == "n8n-postgresql-dashboard") |
    .files[] | select(. == "dashboards/n8n-postgresql.json")] | length' \
    "$prometheus_config")" == '1' ]] || {
  echo 'The n8n dashboard must be packaged exactly once.' >&2
  exit 1
}
validate_n8n_alert_activation

expected_alerts='N8nCanaryDown,N8nCanaryProbeMissing,N8nContainerOomKilled,N8nContainerRestarting,N8nExecutionFailures,N8nPersistentVolumeClaimNotBound,N8nPersistentVolumeUsageCritical,N8nPersistentVolumeUsageWarning,N8nPostgresqlBackupJobFailed,N8nPostgresqlBackupJobOverdue,N8nPostgresqlBackupStale,N8nPostgresqlUnavailable,N8nPostgresqlWorkloadUnavailable,N8nUnavailable,N8nWorkloadUnavailable'
[[ "$(yq -r '[.spec.groups[].rules[] | select(has("alert")) | .alert] | sort | join(",")' \
    "$n8n_alerts")" == \
  "$expected_alerts" ]] || {
  echo 'The n8n PrometheusRule must contain the exact approved alert inventory.' >&2
  exit 1
}
[[ "$(yq -r '[.spec.groups[].rules[] | select(has("record"))] | length' \
    "$n8n_alerts")" == '0' ]] || {
  echo 'The n8n PrometheusRule must not couple alert evaluation to a health recording rule.' >&2
  exit 1
}

expected_panels='Authenticated public canary|Container restarts|Execution duration p95|Execution success and failure rate|OOM termination state|Persistent volume utilization|Platform CPU|Platform memory|PostgreSQL connections|PostgreSQL database size|Ready replicas|Validated logical backup age|Validated logical backup status'
[[ "$(jq -r '.uid' "$n8n_dashboard")" == 'n8n-postgresql' && \
  "$(jq -r '[.templating.list[] | select(.name == "datasource" and .type == "datasource" and .query == "prometheus")] | length' "$n8n_dashboard")" == '1' && \
  "$(jq -r '.templating.list | length' "$n8n_dashboard")" == '1' && \
  "$(jq -r '[.panels[].title] | sort | join("|")' "$n8n_dashboard")" == \
    "$expected_panels" && \
  "$(jq -r '[.panels[] | select(.datasource != {"type":"prometheus","uid":"${datasource}"})] | length' "$n8n_dashboard")" == '0' ]] || {
  echo 'The n8n PostgreSQL dashboard identity, datasource, and panel inventory are incorrect.' >&2
  exit 1
}

canary_endpoint="$(yq -o=json -I=0 '.config.endpoints[] | select(.group == "Platform" and .name == "n8n-platform-canary")' "$gatus_canary_activation")"
canary_group="$(yq -r '.group' - <<<"$canary_endpoint")"
canary_name="$(yq -r '.name' - <<<"$canary_endpoint")"
canary_correlation="$(yq -r '.body | from_json | .correlation' - <<<"$canary_endpoint")"
expected_canary_url="https://$(yq -r '.spec.dnsNames[0]' "$public_certificate")$(yq -r '.spec.rules[0].matches[0].path.value' "$public_route")"
[[ "$(yq -r '.url' - <<<"$canary_endpoint")" == "$expected_canary_url" && \
  "$(yq -r '.method' - <<<"$canary_endpoint")" == 'POST' && \
  "$(yq -r '.interval' - <<<"$canary_endpoint")" == '5m' && \
  "$canary_correlation" == 'gatus-platform-canary' ]] || {
  echo 'The Gatus canary URL must match the dedicated public certificate and exact route.' >&2
  exit 1
}
# shellcheck disable=SC2016 # The expected value is a literal Gatus environment placeholder.
[[ "$(yq -r '.env.GATUS_N8N_CANARY_TOKEN.valueFrom.secretKeyRef | [.name,.key] | join(",")' \
    "$gatus_canary_activation")" == 'n8n-canary,token' && \
  "$(yq -r '.headers."X-Platform-Canary"' - <<<"$canary_endpoint")" == \
    '${GATUS_N8N_CANARY_TOKEN}' ]] || {
  echo 'The Gatus canary authentication must consume only gatus/n8n-canary token.' >&2
  exit 1
}
canary_down_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nCanaryDown") | .expr' "$n8n_alerts")"
canary_missing_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nCanaryProbeMissing") | .expr' "$n8n_alerts")"
canary_dashboard_expr="$(jq -r '.panels[] | select(.title == "Authenticated public canary") | .targets[].expr' "$n8n_dashboard")"
canary_matcher="group=\"$canary_group\",name=\"$canary_name\""
[[ "$canary_down_expr" == *"group=\"$canary_group\""* && \
  "$canary_down_expr" == *"name=\"$canary_name\""* && \
  "$canary_missing_expr" == *"group=\"$canary_group\""* && \
  "$canary_missing_expr" == *"name=\"$canary_name\""* && \
  "$canary_dashboard_expr" == *"$canary_matcher"* ]] || {
  echo 'The Gatus canary, Prometheus alerts, and dashboard must use one endpoint identity.' >&2
  exit 1
}

backup_metric="$(yq -r '.collectors[].metrics[] | select(.query | contains("platform_operations.logical_backup_status")) | .metric_name' "$postgresql_exporter")"
backup_alert_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nPostgresqlBackupStale") | .expr' "$n8n_alerts")"
backup_age_expr="$(jq -r '.panels[] | select(.title == "Validated logical backup age") | .targets[].expr' "$n8n_dashboard")"
backup_status_expr="$(jq -r '.panels[] | select(.title == "Validated logical backup status") | .targets[].expr' "$n8n_dashboard")"
[[ "$backup_metric" == 'n8n_postgresql_backup_last_success_timestamp_seconds' && \
  "$backup_alert_expr" == *"$backup_metric"* && \
  "$backup_age_expr" == *"$backup_metric"* && \
  "$backup_status_expr" == *"$backup_metric"* && \
  "$backup_alert_expr$backup_age_expr$backup_status_expr" != *'kube_job_status_succeeded'* ]] || {
  echo 'Backup observability must use the validated logical-dump status marker.' >&2
  exit 1
}

backup_cronjob_name="$(yq -r '.metadata.name' "$postgresql_cronjob")"
backup_job_failure_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nPostgresqlBackupJobFailed") | .expr' "$n8n_alerts")"
[[ "$backup_job_failure_expr" == *'kube_job_failed{'* && \
  "$backup_job_failure_expr" == *'condition="true"'* && \
  "$backup_job_failure_expr" == *'kube_job_status_start_time{'* && \
  "$backup_job_failure_expr" == *'kube_cronjob_status_last_successful_time{'* && \
  "$backup_job_failure_expr" == *"cronjob=\"$backup_cronjob_name\""* && \
  "$backup_job_failure_expr" != *'kube_job_status_failed'* ]] || {
  echo 'The backup Job failure alert must use terminal failure and last-success recovery semantics.' >&2
  exit 1
}

execution_alert_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nExecutionFailures") | .expr' "$n8n_alerts")"
execution_rate_expr="$(jq -r '.panels[] | select(.title == "Execution success and failure rate") | .targets[].expr' "$n8n_dashboard")"
execution_duration_expr="$(jq -r '.panels[] | select(.title == "Execution duration p95") | .targets[].expr' "$n8n_dashboard")"
[[ "$execution_alert_expr" == *'n8n_workflow_execution_duration_seconds_count'* && \
  "$execution_alert_expr" == *'status="failed"'* && \
  "$execution_rate_expr" == *'n8n_workflow_execution_duration_seconds_count'* && \
  "$execution_duration_expr" == *'n8n_workflow_execution_duration_seconds_bucket'* ]] || {
  echo 'n8n execution alerts and dashboard must use the pinned duration histogram contract.' >&2
  exit 1
}

n8n_deployment_name="$(yq -r '.spec.postRenderers[0].kustomize.patches[] |
  select(.target.kind == "Deployment") | .patch | from_yaml | .[] |
  select(.path == "/metadata/name") | .value' "$n8n_release")"
postgresql_workload_name="$(yq -r '.metadata.name' "$postgresql_statefulset")"
n8n_workload_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nWorkloadUnavailable") | .expr' "$n8n_alerts")"
postgresql_workload_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nPostgresqlWorkloadUnavailable") | .expr' "$n8n_alerts")"
ready_replicas_expr="$(jq -r '.panels[] | select(.title == "Ready replicas") | .targets[].expr' "$n8n_dashboard")"
[[ "$n8n_workload_expr" == *"deployment=\"$n8n_deployment_name\""* && \
  "$postgresql_workload_expr" == *"statefulset=\"$postgresql_workload_name\""* && \
  "$ready_replicas_expr" == *"deployment=\"$n8n_deployment_name\""* && \
  "$ready_replicas_expr" == *"statefulset=\"$postgresql_workload_name\""* ]] || {
  echo 'n8n availability alerts and dashboard must match the deployed workload identities.' >&2
  exit 1
}

pvc_inventory="$(yq -r '.metadata.name' "$n8n_pvc")"
while IFS= read -r postgresql_pvc; do
  pvc_inventory+="|$postgresql_pvc"
done < <(yq ea -N -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$postgresql_pvcs")
pvc_matcher="persistentvolumeclaim=~\"$pvc_inventory\""
pvc_alert_exprs="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nPersistentVolumeClaimNotBound" or .alert == "N8nPersistentVolumeUsageWarning" or .alert == "N8nPersistentVolumeUsageCritical") | .expr' "$n8n_alerts")"
pvc_dashboard_expr="$(jq -r '.panels[] | select(.title == "Persistent volume utilization") | .targets[].expr' "$n8n_dashboard")"
[[ "$pvc_inventory" == 'n8n-data|n8n-postgresql-data|n8n-postgresql-backups' && \
  "$(rg -Foc "$pvc_matcher" <<<"$pvc_alert_exprs")" -eq 5 && \
  "$(rg -Foc "$pvc_matcher" <<<"$pvc_dashboard_expr")" -eq 2 ]] || {
  echo 'n8n alert and dashboard PVC inventories must match the three retained claims.' >&2
  exit 1
}
pvc_warning_expr="$(yq -r '.spec.groups[].rules[] | select(.alert == "N8nPersistentVolumeUsageWarning") | .expr' "$n8n_alerts")"
[[ "$pvc_warning_expr" == *'> 70'* && "$pvc_warning_expr" == *'<= 85'* ]] || {
  echo 'The n8n PVC warning range must stop at 85 percent.' >&2
  exit 1
}

connection_metric="$(yq -r '.collectors[].metrics[] | select(.key_labels == ["state"]) | .metric_name' "$postgresql_exporter")"
database_size_metric="$(yq -r '.collectors[].metrics[] | select(.values == ["database_size_bytes"]) | .metric_name' "$postgresql_exporter")"
[[ "$(jq -r '.panels[] | select(.title == "PostgreSQL connections") | .targets[].expr' "$n8n_dashboard")" == *"$connection_metric"* && \
  "$(jq -r '.panels[] | select(.title == "PostgreSQL database size") | .targets[].expr' "$n8n_dashboard")" == *"$database_size_metric"* ]] || {
  echo 'The PostgreSQL dashboard panels must use the Task 4 SQL Exporter metrics.' >&2
  exit 1
}

[[ "$(yq -r '.metadata.name' "$n8n_pvc")" == 'n8n-data' && \
  "$(yq -r '.metadata.annotations."kustomize.toolkit.fluxcd.io/prune"' "$n8n_pvc")" == \
    'disabled' && \
  "$(yq -r '.spec.accessModes | join(",")' "$n8n_pvc")" == 'ReadWriteOnce' && \
  "$(yq -r '.spec.resources.requests.storage' "$n8n_pvc")" == '5Gi' && \
  "$(yq -r '.spec.storageClassName' "$n8n_pvc")" == 'longhorn' ]] || {
  echo 'n8n-data must be a retained 5Gi Longhorn RWO claim.' >&2
  exit 1
}
[[ "$(yq -r '.metadata.annotations."external-dns.k8s.io/audience"' "$n8n_route")" == \
    'internal' && \
  "$(yq -r '.spec.hostnames | join(",")' "$n8n_route")" == 'n8n.lab.supermorphic.com' && \
  "$(yq -r '.spec.parentRefs | length' "$n8n_route")" == '1' && \
  "$(yq -r '.spec.parentRefs[0] | [.namespace, .name, .sectionName] | join(",")' "$n8n_route")" == \
    'networking,internal,https' && \
  "$(yq -r '.spec.rules | length' "$n8n_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs | length' "$n8n_route")" == '1' && \
  "$(yq -r '.spec.rules[0].backendRefs[0] | [.kind, .name, .port] | join(",")' "$n8n_route")" == \
    'Service,n8n,5678' ]] || {
  echo 'The private n8n route must attach only to networking/internal and target n8n:5678.' >&2
  exit 1
}
[[ "$(yq -r '.spec.from | length' "$n8n_grant")" == '1' && \
  "$(yq -r '.spec.from[0] | [.group, .kind, .namespace] | join(",")' "$n8n_grant")" == \
    'gateway.networking.k8s.io,HTTPRoute,networking-public' && \
  "$(yq -r '.spec.to | length' "$n8n_grant")" == '1' && \
  "$(yq -r '.spec.to[0] | [.group, .kind, .name] | join(",")' "$n8n_grant")" == \
    ',Service,n8n' ]] || {
  echo 'The ReferenceGrant must admit only networking-public HTTPRoutes to Service n8n.' >&2
  exit 1
}
[[ "$(yq -r '.spec.selector.matchLabels."app.kubernetes.io/name"' "$n8n_monitor")" == \
    'n8n' && \
  "$(yq -r '[.spec.endpoints[] | .port + ":" + .path] | join(",")' "$n8n_monitor")" == \
    'http:/metrics' ]] || {
  echo 'The n8n ServiceMonitor must scrape only /metrics on the named HTTP port.' >&2
  exit 1
}

expected_n8n_ingress='[{"fromEndpoints":["app.kubernetes.io/name=prometheus,k8s:io.kubernetes.pod.namespace=monitoring,operator.prometheus.io/name=kube-prometheus-stack-prometheus"],"fromEntities":[],"toPorts":["5678/TCP"]},{"fromEndpoints":["gateway.envoyproxy.io/owning-gateway-name=internal,gateway.envoyproxy.io/owning-gateway-namespace=networking,k8s:io.kubernetes.pod.namespace=envoy-gateway-system","gateway.envoyproxy.io/owning-gateway-name=public-webhooks,gateway.envoyproxy.io/owning-gateway-namespace=networking-public,k8s:io.kubernetes.pod.namespace=envoy-gateway-system"],"fromEntities":[],"toPorts":["5678/TCP"]},{"fromEndpoints":[],"fromEntities":["host","remote-node"],"toPorts":["5678/TCP"]}]'
actual_n8n_ingress="$(yq -o=json -I=0 '
  [.spec.ingress[] | {
    "fromEndpoints": ([.fromEndpoints[]?.matchLabels |
      to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")] | sort),
    "fromEntities": ((.fromEntities // []) | sort),
    "toPorts": ([.toPorts[]?.ports[] | .port + "/" + .protocol] | sort)
  }] | sort_by((.fromEndpoints + .fromEntities + .toPorts) | join("|"))
' "$n8n_policy")"
[[ "$(yq -r '.spec | keys | sort | join(",")' "$n8n_policy")" == \
    'egress,endpointSelector,ingress' && \
  "$(yq -o=json -I=0 '.spec.endpointSelector' "$n8n_policy")" == \
    '{"matchLabels":{"app.kubernetes.io/name":"n8n"}}' && \
  "$(yq -r '[.spec.ingress[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == \
    'fromEndpoints,toPorts;fromEndpoints,toPorts;fromEntities,toPorts' && \
  "$(yq -r '[.spec.ingress[].fromEndpoints[]? | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'matchLabels;matchLabels;matchLabels' && \
  "$(yq -r '[.spec.ingress[].toPorts[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'ports;ports;ports' && \
  "$(yq -r '[.spec.ingress[].toPorts[].ports[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'port,protocol;port,protocol;port,protocol' && \
  "$actual_n8n_ingress" == "$expected_n8n_ingress" ]] || {
  echo 'n8n ingress must admit only both Envoy data planes, Prometheus, and kubelet probes.' >&2
  exit 1
}
expected_n8n_egress='[{"toEndpoints":[],"toCIDRSet":["0.0.0.0/0 except=0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.0.0.0/24,192.0.2.0/24,192.168.0.0/16,192.88.99.0/24,198.18.0.0/15,198.51.100.0/24,203.0.113.0/24,224.0.0.0/4,240.0.0.0/4"],"toPorts":["443/TCP"]},{"toEndpoints":["app.kubernetes.io/name=n8n-postgresql,k8s:io.kubernetes.pod.namespace=automation"],"toCIDRSet":[],"toPorts":["5432/TCP"]},{"toEndpoints":["k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns"],"toCIDRSet":[],"toPorts":["53/TCP","53/UDP"]}]'
actual_n8n_egress="$(yq -o=json -I=0 '
  [.spec.egress[] | {
    "toEndpoints": ([.toEndpoints[]?.matchLabels |
      to_entries | sort_by(.key) | map(.key + "=" + .value) | join(",")] | sort),
    "toCIDRSet": ([.toCIDRSet[]? |
      .cidr + " except=" + ((.except // []) | sort | join(","))] | sort),
    "toPorts": ([.toPorts[]?.ports[] | .port + "/" + .protocol] | sort)
  }] | sort_by((.toEndpoints + .toCIDRSet + .toPorts) | join("|"))
' "$n8n_policy")"
[[ "$(yq -r '[.spec.egress[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == \
    'toCIDRSet,toPorts;toEndpoints,toPorts;toEndpoints,toPorts' && \
  "$(yq -r '[.spec.egress[].toEndpoints[]? | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'matchLabels;matchLabels' && \
  "$(yq -r '[.spec.egress[].toCIDRSet[]? | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'cidr,except' && \
  "$(yq -r '[.spec.egress[].toPorts[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == 'ports;ports;ports' && \
  "$(yq -r '[.spec.egress[].toPorts[].ports[] | keys | sort | join(",")] | sort | join(";")' \
    "$n8n_policy")" == \
    'port,protocol;port,protocol;port,protocol;port,protocol' && \
  "$actual_n8n_egress" == "$expected_n8n_egress" ]] || {
  echo 'n8n egress must reach only DNS, PostgreSQL, and public IPv4 HTTPS.' >&2
  exit 1
}

kustomize build "$n8n_app" >"$temp_dir/n8n-source.yaml"
yq ea 'del(.sops)' "$temp_dir/n8n-source.yaml" >"$temp_dir/n8n-source-conform.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/n8n-source-conform.yaml"
chart_pull_output="$(helm pull "$(yq -r '.spec.url' "$n8n_source")" --version 1.11.0 \
  --destination "$temp_dir")"
rg -Fq 'Digest: sha256:a0bf4694f6e0f91dfb196fd8de08ad40cb3dd798edaa9bd54fa9c3f32566517c' \
  <<<"$chart_pull_output" || {
  echo 'The downloaded n8n chart does not match the pinned OCI digest.' >&2
  exit 1
}
helm template n8n "$temp_dir/n8n-1.11.0.tgz" --namespace automation \
  --values "$n8n_values" >"$temp_dir/n8n-chart.yaml"
# Apply the exact declared Flux post-render patches with Kustomize. A target that does
# not match the pinned chart remains unmodified and fails the rendered-name assertions.
mkdir -p "$temp_dir/n8n-postrender"
cp "$temp_dir/n8n-chart.yaml" "$temp_dir/n8n-postrender/resources.yaml"
n8n_release="$n8n_release" yq -n '
  .apiVersion = "kustomize.config.k8s.io/v1beta1" |
  .kind = "Kustomization" |
  .resources = ["./resources.yaml"] |
  .patches = load(strenv(n8n_release)).spec.postRenderers[0].kustomize.patches
' >"$temp_dir/n8n-postrender/kustomization.yaml"
kustomize build "$temp_dir/n8n-postrender" >"$temp_dir/n8n-rendered.yaml"
kubeconform -strict -summary -ignore-missing-schemas "$temp_dir/n8n-rendered.yaml"

[[ "$(yq ea -r '[select(.kind == "Deployment")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/n8n-rendered.yaml")" == \
    'n8n' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.replicas' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/n8n-rendered.yaml")" == \
    'Recreate' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers | length' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$temp_dir/n8n-rendered.yaml")" == \
    'docker.n8n.io/n8nio/n8n:2.36.7' ]] || {
  echo 'The n8n chart must render one exact-image Deployment replica with Recreate.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "Service")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r 'select(.kind == "Service") | [.metadata.name, .spec.type, .spec.ports[0].name, .spec.ports[0].port] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'n8n,ClusterIP,http,5678' && \
  "$(yq ea -r '[select(.kind == "Deployment") | .spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'n8n-data' ]] || {
  echo 'The n8n chart must expose n8n:5678 and mount only the retained n8n-data claim.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources | [.requests.cpu, .requests.memory, .limits.memory] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    '100m,256Mi,1Gi' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].resources.limits | has("cpu") | not' "$temp_dir/n8n-rendered.yaml")" == \
    'true' && \
  "$(yq ea -r 'select(.kind == "Deployment") | .spec.template.spec.automountServiceAccountToken' "$temp_dir/n8n-rendered.yaml")" == \
    'false' && \
  "$(yq ea -r '[select(.kind == "Role" or .kind == "RoleBinding" or .kind == "ServiceAccount")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '0' ]] || {
  echo 'The n8n pod must use the exact resource envelope without Kubernetes API credentials.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment") | [.spec.template.spec.containers[0].env[] | select(.name == "DB_POSTGRESDB_PASSWORD") | .valueFrom.secretKeyRef | [.name, .key] | join(",")] | join(";")' "$temp_dir/n8n-rendered.yaml")" == \
    'postgresql-credentials,n8n-password' && \
  "$(yq ea -r 'select(.kind == "ConfigMap") | [.data.DB_TYPE, .data.DB_POSTGRESDB_HOST, .data.DB_POSTGRESDB_PORT, .data.DB_POSTGRESDB_DATABASE, .data.DB_POSTGRESDB_USER] | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'postgresdb,n8n-postgresql.automation.svc.cluster.local,5432,n8n,n8n' ]] || {
  echo 'The n8n chart must use only the dedicated external PostgreSQL database.' >&2
  exit 1
}
[[ "$(yq ea -r 'select(.kind == "Deployment") | [.spec.template.spec.containers[0].env[] | select(.valueFrom.secretKeyRef != null) | .name + "=" + .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key] | sort | join(",")' "$temp_dir/n8n-rendered.yaml")" == \
    'DB_POSTGRESDB_PASSWORD=postgresql-credentials/n8n-password,N8N_ENCRYPTION_KEY=n8n-runtime/N8N_ENCRYPTION_KEY,N8N_HOST=n8n-runtime/N8N_HOST,N8N_PORT=n8n-runtime/N8N_PORT,N8N_PROTOCOL=n8n-runtime/N8N_PROTOCOL' ]] || {
  echo 'The n8n container must consume only the exact runtime and database Secret keys.' >&2
  exit 1
}
[[ -z "$(yq ea -r 'select(.kind == "ConfigMap") | .data | keys | .[] | select(test("REDIS|QUEUE"))' \
    "$temp_dir/n8n-rendered.yaml")" && \
  "$(yq ea -r '[select(.kind == "Deployment" and .metadata.labels."app.kubernetes.io/component" != "main")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '0' && \
  "$(yq ea -r '[select(.kind == "Secret" or .kind == "HorizontalPodAutoscaler" or .kind == "PodDisruptionBudget" or .kind == "Ingress" or .kind == "ScaledObject")] | length' "$temp_dir/n8n-rendered.yaml")" == \
    '0' ]] || {
  echo 'The n8n chart must not render queue, Redis, worker, webhook-processor, autoscaling, disruption-budget, or Ingress behavior.' >&2
  exit 1
}

n8n_env_query='select(.kind == "Deployment") | .spec.template.spec.containers[0].env'
[[ "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_WEBHOOK_URL\")] | length" "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_EDITOR_BASE_URL\")] | length" "$temp_dir/n8n-rendered.yaml")" == \
    '1' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"WEBHOOK_URL\")] | length" "$temp_dir/n8n-rendered.yaml")" == \
    '0' && \
  "$(yq ea -r 'select(.kind == "ConfigMap") | .data | has("WEBHOOK_URL")' "$temp_dir/n8n-rendered.yaml")" == \
    'false' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_WEBHOOK_URL\") | .value, .[] | select(.name == \"N8N_EDITOR_BASE_URL\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'https://hooks.lab.supermorphic.com/,https://n8n.lab.supermorphic.com/' ]] || {
  echo 'The n8n container must have each canonical URL once and no deprecated WEBHOOK_URL.' >&2
  exit 1
}
[[ "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_PROXY_HOPS\") | .value, .[] | select(.name == \"N8N_METRICS\") | .value, .[] | select(.name == \"N8N_METRICS_INCLUDE_WORKFLOW_STATISTICS\") | .value, .[] | select(.name == \"N8N_METRICS_INCLUDE_DB_POOL_METRICS\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    '1,true,true,true' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_DIAGNOSTICS_ENABLED\" or .name == \"N8N_VERSION_NOTIFICATIONS_ENABLED\" or .name == \"N8N_PERSONALIZATION_ENABLED\") | .name + \"=\" + .value] | sort | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'N8N_DIAGNOSTICS_ENABLED=false,N8N_PERSONALIZATION_ENABLED=false,N8N_VERSION_NOTIFICATIONS_ENABLED=false' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL\" or .name == \"N8N_METRICS_INCLUDE_NODE_TYPE_LABEL\" or .name == \"N8N_METRICS_INCLUDE_CREDENTIAL_TYPE_LABEL\") | .name + \"=\" + .value] | sort | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'N8N_METRICS_INCLUDE_CREDENTIAL_TYPE_LABEL=false,N8N_METRICS_INCLUDE_NODE_TYPE_LABEL=false,N8N_METRICS_INCLUDE_WORKFLOW_ID_LABEL=false' && \
  "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"N8N_DEFAULT_BINARY_DATA_MODE\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'filesystem' ]] || {
  echo 'The n8n proxy, metrics, telemetry, and filesystem settings are incorrect.' >&2
  exit 1
}
[[ "$(yq ea -r "$n8n_env_query | [.[] | select(.name == \"EXECUTIONS_DATA_SAVE_ON_ERROR\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_SAVE_ON_SUCCESS\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_PRUNE\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_MAX_AGE\") | .value, .[] | select(.name == \"EXECUTIONS_DATA_PRUNE_MAX_COUNT\") | .value] | join(\",\")" "$temp_dir/n8n-rendered.yaml")" == \
    'all,all,true,336,10000' ]] || {
  echo 'n8n must save success and error executions and enforce both retention bounds.' >&2
  exit 1
}

echo 'n8n standalone external-PostgreSQL render, private route, retained storage, metrics, and containment passed validation.'
