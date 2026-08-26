#!/usr/bin/env bash
set -euo pipefail

render="${1:?usage: alloy-logs-render.sh RENDERED_YAML [WORKLOAD_KIND WORKLOAD_NAME RUN_AS_USER]}"
workload_kind="${2:-DaemonSet}"
workload_name="${3:-alloy-logs}"
run_as_user="${4:-0}"

alloy_container() {
  yq ea -r \
    'select(.kind == "'"$workload_kind"'" and .metadata.name == "'"$workload_name"'") |
     .spec.template.spec.containers[] | select(.name == "alloy") | '"$1" \
    "$render"
}

[[ "$(alloy_container '.image')" == 'docker.io/grafana/alloy:v1.19.0' ]] || {
  echo 'Refusing: rendered Alloy image must be docker.io/grafana/alloy:v1.19.0.' >&2
  exit 1
}
[[ "$(alloy_container '.securityContext.allowPrivilegeEscalation')" == 'false' ]] || {
  echo 'Refusing: rendered Alloy must disable privilege escalation.' >&2
  exit 1
}
[[ "$(alloy_container '.securityContext.privileged')" == 'false' ]] || {
  echo 'Refusing: rendered Alloy must disable privileged mode.' >&2
  exit 1
}
[[ "$(alloy_container '.securityContext.capabilities.drop | unique | sort | join(",")')" == 'ALL' ]] || {
  echo 'Refusing: rendered Alloy must drop every Linux capability.' >&2
  exit 1
}
[[ "$(alloy_container '(.securityContext.capabilities.add // []) | length')" == '0' ]] || {
  echo 'Refusing: rendered Alloy must not add Linux capabilities.' >&2
  exit 1
}
[[ "$(alloy_container '.securityContext.readOnlyRootFilesystem')" == 'true' ]] || {
  echo 'Refusing: rendered Alloy root filesystem must be read-only.' >&2
  exit 1
}
[[ "$(alloy_container '.securityContext.runAsUser')" == "$run_as_user" ]] || {
  if [[ "$workload_name" == 'alloy-logs' && "$run_as_user" == '0' ]]; then
    echo 'Refusing: rendered Alloy UID must remain 0 for Talos mode-0640 logs.' >&2
  else
    echo "Refusing: rendered Alloy UID must remain $run_as_user for $workload_name." >&2
  fi
  exit 1
}
if [[ "$run_as_user" != '0' ]]; then
  [[ "$(alloy_container '.securityContext.runAsNonRoot')" == 'true' ]] || {
    echo "Refusing: rendered Alloy must run as non-root for $workload_name." >&2
    exit 1
  }
  [[ "$(alloy_container '.securityContext.runAsGroup')" == "$run_as_user" ]] || {
    echo "Refusing: rendered Alloy group must remain $run_as_user for $workload_name." >&2
    exit 1
  }
fi
[[ "$(alloy_container '.securityContext.seccompProfile.type')" == 'RuntimeDefault' ]] || {
  echo 'Refusing: rendered Alloy must use the RuntimeDefault seccomp profile.' >&2
  exit 1
}

[[ "$(yq ea -r '[select(.kind == "'"$workload_kind"'" and .metadata.name == "'"$workload_name"'") | (.spec.template.spec.hostPID // false)] | join(",")' "$render")" == 'false' ]] || {
  echo 'Refusing: rendered Alloy must not use the host PID namespace.' >&2
  exit 1
}
[[ "$(yq ea -r '[select(.kind == "'"$workload_kind"'" and .metadata.name == "'"$workload_name"'") | (.spec.template.spec.hostNetwork // false)] | join(",")' "$render")" == 'false' ]] || {
  echo 'Refusing: rendered Alloy must not use the host network namespace.' >&2
  exit 1
}

echo 'Rendered Alloy image and container hardening passed validation.'
