#!/usr/bin/env bash
# Offline command tests for the fixed NocoDB platform prerequisite Job.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

command_path='scripts/nocodb/platform-preflight.sh'
postgresql_policy='kubernetes/apps/automation-data/postgresql/app/ciliumnetworkpolicy.yaml'
backup_cronjob='kubernetes/apps/automation-data/postgresql/app/cronjob.yaml'
[[ -x "$command_path" ]] || {
  echo "Missing executable NocoDB platform preflight: $command_path" >&2
  exit 1
}
[[ -f "$postgresql_policy" && -f "$backup_cronjob" ]] || {
  echo 'Missing PostgreSQL policy or backup workload contract.' >&2
  exit 1
}

! rg -n 'get secret|jsonpath=.*data\.|--command=.*\$' "$command_path" >/dev/null || {
  echo 'NocoDB platform preflight retrieves Secret data or accepts mutable SQL.' >&2
  exit 1
}

fixture="$(mktemp -d "${TMPDIR:-/tmp}/homelab-nocodb-platform-preflight.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/case"
touch "$fixture/kubeconfig" "$fixture/events.log"

export PREFLIGHT_TEST_ROOT="$fixture/case"
export PREFLIGHT_TEST_LOG="$fixture/events.log"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$PREFLIGHT_TEST_LOG"
args=" $* "
job="$PREFLIGHT_TEST_ROOT/job.yaml"
replacement="$PREFLIGHT_TEST_ROOT/replacement.yaml"
argument_after() {
  local wanted="$1" previous='' argument
  shift
  for argument in "$@"; do
    [[ "$previous" != "$wanted" ]] || { printf '%s\n' "$argument"; return; }
    previous="$argument"
  done
  return 1
}
job_name_from_resource() {
  local argument
  for argument in "$@"; do
    case "$argument" in job/*) printf '%s\n' "${argument#job/}"; return ;; esac
  done
  return 1
}
matching_job() {
  local requested="$1" candidate candidate_name
  for candidate in "$job" "$replacement"; do
    [[ -f "$candidate" ]] || continue
    candidate_name="$(yq -r '.metadata.name' "$candidate")"
    [[ "$candidate_name" != "$requested" ]] || { printf '%s\n' "$candidate"; return; }
  done
  return 1
}
if [[ "$args" == *' get job '*' --ignore-not-found --output name '* ]]; then
  requested="$(argument_after job "$@")"
  [[ "${PREFLIGHT_TEST_CASE:-}" != api-error ]] || exit 69
  found="$(matching_job "$requested" || true)"
  [[ -z "$found" ]] || printf 'job.batch/%s\n' "$requested"
elif [[ "$args" == *' get job '*' --ignore-not-found --output json '* ]]; then
  requested="$(argument_after job "$@")"
  [[ "${PREFLIGHT_TEST_CASE:-}" != api-error ]] || exit 69
  found="$(matching_job "$requested" || true)"
  if [[ -n "$found" ]]; then
    current_json="$(yq -o=json "$found")"
    if [[ "${PREFLIGHT_TEST_CASE:-}" == replacement-race ]]; then
      if [[ "$requested" == nocodb-platform-preflight ]]; then
        yq '.metadata.uid = "replacement-uid" |
          .metadata.labels."homelab-talos/run-id" = "other-run"' \
          "$found" >"$PREFLIGHT_TEST_ROOT/replaced.yaml"
        mv "$PREFLIGHT_TEST_ROOT/replaced.yaml" "$found"
      else
        yq '.metadata.name = "nocodb-platform-preflight-other-run" |
          .metadata.uid = "replacement-uid" |
          .metadata.labels."homelab-talos/run-id" = "other-run"' \
          "$found" >"$replacement"
      fi
    fi
    printf '%s\n' "$current_json"
  fi
elif [[ "$args" == *' create --filename - '* ]]; then
  cat >"$job"
  yq '.metadata.uid = "owned-uid"' "$job" >"$PREFLIGHT_TEST_ROOT/created.yaml"
  mv "$PREFLIGHT_TEST_ROOT/created.yaml" "$job"
  [[ -z "${PREFLIGHT_JOB_SNAPSHOT:-}" ]] || cp "$job" "$PREFLIGHT_JOB_SNAPSHOT"
  printf '%s\n' create-job >>"$PREFLIGHT_TEST_LOG"
  [[ "${PREFLIGHT_TEST_CASE:-}" != ambiguous-create ]] || exit 74
elif [[ "$args" == *' wait --for=condition=Complete job/'*' --timeout=2m '* ]]; then
  requested="$(job_name_from_resource "$@")"
  [[ -n "$(matching_job "$requested" || true)" ]] || exit 68
  [[ "${PREFLIGHT_TEST_CASE:-}" != job-failed ]] || exit 75
elif [[ "$args" == *' logs job/'*' --container=preflight '* ]]; then
  requested="$(job_name_from_resource "$@")"
  [[ -n "$(matching_job "$requested" || true)" ]] || exit 68
  if [[ "${PREFLIGHT_TEST_CASE:-}" == invalid-output ]]; then
    printf '%s\n' 'installed_revision=025-platform-v1' 'post_upgrade_backup=true'
  else
    printf '%s\n' 'installed_revision=026-nocodb-v1' 'post_upgrade_backup=true'
  fi
elif [[ "$args" == *' get pods --selector='*'--output json '* ]]; then
  printf '%s\n' '{"items":[{"status":{"phase":"Failed","containerStatuses":[{"name":"preflight","state":{"terminated":{"reason":"Error","exitCode":1}}}]}}]}'
elif [[ "$args" == *' delete job '*' --wait=true --timeout=2m '* ]]; then
  requested="$(argument_after job "$@")"
  for candidate in "$job" "$replacement"; do
    [[ -f "$candidate" ]] || continue
    [[ "$(yq -r '.metadata.name' "$candidate")" != "$requested" ]] || rm -f -- "$candidate"
  done
  printf '%s\n' delete-job >>"$PREFLIGHT_TEST_LOG"
else
  echo "Unexpected kubectl invocation: $*" >&2
  exit 64
fi
EOF
chmod 700 "$fixture/bin/kubectl"

fail() { echo "NocoDB platform preflight test failed: $*" >&2; exit 1; }

run_case() {
  local name="$1"
  rm -f -- "$fixture/case/job.yaml" "$fixture/case/replacement.yaml"
  : >"$fixture/events.log"
  set +e
  output="$(PATH="$fixture/bin:$PATH" PREFLIGHT_TEST_CASE="$name" \
    "$command_path" "$fixture/kubeconfig" 2>&1)"
  status=$?
  set -e
}

run_case success
[[ "$status" -eq 0 ]] || fail "success failed: $output"
[[ "$output" == $'installed_revision=026-nocodb-v1\npost_upgrade_backup=true' ]] ||
  fail "success exposed unexpected output: $output"
rg -Fxq create-job "$fixture/events.log" || fail 'success did not create the fixed Job'
rg -Fxq delete-job "$fixture/events.log" || fail 'success did not remove the fixed Job'
[[ ! -e "$fixture/case/job.yaml" ]] || fail 'success left the fixed Job behind'

job_snapshot="$fixture/job-snapshot.yaml"
# Re-run create with an ambiguous response so the rendered Job remains available for inspection
# until the command's ownership-aware cleanup reads and removes it.
run_case ambiguous-create
[[ "$status" -ne 0 ]] || fail 'ambiguous create response was accepted'
rg -Fxq create-job "$fixture/events.log" || fail 'ambiguous create did not reach the API'
rg -Fxq delete-job "$fixture/events.log" || fail 'ambiguous create did not remove its owned Job'
[[ ! -e "$fixture/case/job.yaml" ]] || fail 'ambiguous create left its owned Job'

for rejected in job-failed invalid-output api-error; do
  run_case "$rejected"
  [[ "$status" -ne 0 ]] || fail "$rejected was accepted"
  if [[ "$rejected" != api-error ]]; then
    rg -Fxq delete-job "$fixture/events.log" || fail "$rejected did not clean its Job"
    [[ ! -e "$fixture/case/job.yaml" ]] || fail "$rejected left its Job"
  fi
done

run_case replacement-race
[[ "$status" -eq 0 ]] || fail "replacement race failed: $output"
[[ -f "$fixture/case/replacement.yaml" ]] ||
  fail 'cleanup deleted the concurrently created Job from another run'
[[ "$(yq -r '.metadata.name + "|" + .metadata.uid + "|" +
  .metadata.labels."homelab-talos/run-id"' "$fixture/case/replacement.yaml")" == \
  'nocodb-platform-preflight-other-run|replacement-uid|other-run' ]] ||
  fail 'replacement-race fixture did not preserve the other run identity'

# Capture one successful render for the fixed manifest contract checks.
PREFLIGHT_JOB_SNAPSHOT="$job_snapshot" run_case success
[[ "$status" -eq 0 && -f "$job_snapshot" ]] || fail 'could not capture the rendered Job'
yq -e '
  .apiVersion == "batch/v1" and .kind == "Job" and
  (.metadata.name | test("^nocodb-platform-preflight-[a-z0-9]+-[0-9]+$")) and
  .metadata.namespace == "automation-data" and
  .metadata.labels."homelab-talos/role" == "nocodb-platform-preflight" and
  .spec.activeDeadlineSeconds == 120 and .spec.backoffLimit == 0 and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.restartPolicy == "Never" and
  (.spec.template.spec.containers | length) == 1 and
  .spec.template.spec.containers[0].name == "preflight" and
  .spec.template.spec.containers[0].image == "postgres:17.11-alpine3.24"
' "$job_snapshot" >/dev/null ||
  fail "rendered Job differs from its fixed bounded contract: $(yq -o=json -I=0 '.' "$job_snapshot")"
run_label="$(yq -r '.metadata.labels."homelab-talos/run-id"' "$job_snapshot")"
[[ "$run_label" =~ ^[A-Za-z0-9.-]{1,63}$ ]] || fail 'rendered Job has an unsafe run label'
[[ "$(yq -r '.spec.template.spec.containers[0].env[] | select(.name == "PGPASSWORD") |
  [.valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key] | join("|")' "$job_snapshot")" == \
  'postgresql-credentials|backup-password' ]] || fail 'rendered Job does not use the fixed backup Secret reference'
job_client_label="$(yq -r '.spec.template.metadata.labels."app.kubernetes.io/name"' "$job_snapshot")"
[[ "$job_client_label" == automation-data-postgresql-backup ]] ||
  fail 'rendered Job does not use the existing PostgreSQL backup-client identity'
mise exec -- yq -e '
  select(.metadata.name == "automation-data-postgresql") |
  [.spec.ingress[].fromEndpoints[] | select(
    .matchLabels."k8s:io.kubernetes.pod.namespace" == "automation-data" and
    .matchLabels."app.kubernetes.io/name" == "automation-data-postgresql-backup"
  )] | length == 1
' "$postgresql_policy" >/dev/null || fail 'PostgreSQL ingress policy does not admit the fixed preflight client label'
mise exec -- yq -e '
  select(.metadata.name == "automation-data-postgresql-backup") |
  .spec.endpointSelector.matchLabels."app.kubernetes.io/name" == "automation-data-postgresql-backup" and
  ([.spec.egress[].toEndpoints[] | select(
    .matchLabels."k8s:io.kubernetes.pod.namespace" == "automation-data" and
    .matchLabels."app.kubernetes.io/name" == "automation-data-postgresql"
  )] | length == 1)
' "$postgresql_policy" >/dev/null || fail 'backup-client egress policy does not admit the fixed PostgreSQL target'
[[ "$(yq -r '.spec.jobTemplate.spec.template.spec.containers[0].image' "$backup_cronjob")" == \
  "$(yq -r '.spec.template.spec.containers[0].image' "$job_snapshot")" ]] ||
  fail 'preflight Job image differs from the current pinned backup-client image'
[[ "$(yq -o=json -I=0 '.spec.jobTemplate.spec.template.spec.securityContext |
  {"runAsNonRoot": .runAsNonRoot, "runAsUser": .runAsUser,
    "runAsGroup": .runAsGroup, "seccompProfile": .seccompProfile}' "$backup_cronjob")" == \
  "$(yq -o=json -I=0 '.spec.template.spec.securityContext |
  {"runAsNonRoot": .runAsNonRoot, "runAsUser": .runAsUser,
    "runAsGroup": .runAsGroup, "seccompProfile": .seccompProfile}' "$job_snapshot")" ]] ||
  fail 'preflight Job pod security context differs from the pinned backup-client pattern'
job_script="$(yq -r '.spec.template.spec.containers[0].args[0]' "$job_snapshot")"
rg -Fq 'BEGIN TRANSACTION READ ONLY' <<<"$job_script" || fail 'Job does not use a read-only transaction'
rg -Fq 'platform_operations.read_platform_revision()' <<<"$job_script" || fail 'Job does not invoke the installed revision oracle'
rg -Fq 'backup.completed_at >= revision.installed_at' <<<"$job_script" || fail 'Job does not prove a post-upgrade backup'
! rg -n 'SELECT \*|information_schema|pg_authid' <<<"$job_script" >/dev/null ||
  fail 'Job contains an unbounded catalog query'

echo 'NocoDB platform preflight command tests passed.'
