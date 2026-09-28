#!/usr/bin/env bash
set -euo pipefail

# The fixture records which resources a containment phase changes. Read calls
# deliberately return independent live state rather than echoing script inputs.
source scripts/operations/qbit-manage-contain.sh

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/qbit-manage-contain-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
kubeconfig="$test_dir/operator-kubeconfig"
touch "$kubeconfig"
expected_revision='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

reset_state() {
  : >"$test_dir/actions"
  declare -gA suspended=([flux-system/flux-system]=false [flux-system/cluster-apps]=false [flux-system/qbit-manage]=false [media/qbit-manage]=false)
  replicas=1
  artifact_revision="main@sha1:$expected_revision"
  applied_revision="main@sha1:$expected_revision"
  git_suspended=true
  fail_wait=''
  stuck_pod=false
  qb_ready=1
}

flux() {
  printf 'flux %s\n' "$*" >>"$test_dir/actions"
  local verb="$1" kind="$2" name="$3" namespace=''
  shift 3
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == '--namespace' ]]; then namespace="$2"; shift; fi
    shift
  done
  if [[ "$verb" == 'suspend' || "$verb" == 'resume' ]]; then
    [[ "$kind" == 'kustomization' || "$kind" == 'helmrelease' ]]
    suspended["$namespace/$name"]=$([[ "$verb" == 'suspend' ]] && echo true || echo false)
  fi
}

kubectl() {
  printf 'kubectl %s\n' "$*" >>"$test_dir/actions"
  local namespace='' command='' kind='' name='' output=''
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --kubeconfig) shift 2 ;;
      --namespace) namespace="$2"; shift 2 ;;
      --output) output="$2"; shift 2 ;;
      get|wait|scale) command="$1"; shift ;;
      kustomization|helmrelease|gitrepository|deployment|pod) kind="$1"; shift ;;
      kustomization/*|helmrelease/*|gitrepository/*|deployment/*) kind="${1%%/*}"; name="${1#*/}"; shift ;;
      flux-system|cluster-apps|qbit-manage|qbittorrent) name="$1"; shift ;;
      --replicas=0) replicas=0; shift ;;
      *) shift ;;
    esac
  done
  if [[ "$command" == 'wait' ]]; then
    [[ "$fail_wait" != "$namespace/$name" ]]
    return
  fi
  if [[ "$command" == 'scale' ]]; then return; fi
  case "$kind:$output" in
    kustomization:*spec.suspend*|helmrelease:*spec.suspend*) printf '%s\n' "${suspended[$namespace/$name]}" ;;
    kustomization:*metadata.generation*|helmrelease:*metadata.generation*) echo 3 ;;
    kustomization:*status.observedGeneration*|helmrelease:*status.observedGeneration*) echo 3 ;;
    kustomization:*status.lastAppliedRevision*) echo "$applied_revision" ;;
    gitrepository:*status.artifact.revision*) echo "$artifact_revision" ;;
    deployment:*spec.replicas*) echo "$replicas" ;;
    deployment:*status.readyReplicas*) echo "$qb_ready" ;;
    pod:*) [[ "$replicas" == 0 && "$stuck_pod" == false ]] || echo pod/qbit-manage-test ;;
    *) echo "Unsupported mock kubectl call: $kind $output" >&2; return 1 ;;
  esac
}

yq() { echo "$git_suspended"; }

assert_order() {
  local previous=0 line pattern
  for pattern in "$@"; do
    line="$(rg -n "$pattern" "$test_dir/actions" | head -1 | cut -d: -f1)"
    [[ -n "$line" && "$line" -gt "$previous" ]] || {
      echo "Missing or out-of-order action: $pattern" >&2
      return 1
    }
    previous="$line"
  done
}

reset_state
contain_stop
assert_order 'flux suspend kustomization flux-system' 'flux suspend kustomization cluster-apps' \
  'flux suspend kustomization qbit-manage' 'flux suspend helmrelease qbit-manage' \
  'kubectl .* scale deployment/qbit-manage --replicas=0'
[[ "$replicas" == 0 && "${suspended[flux-system/flux-system]}" == true ]]
if rg -q 'resume|scale deployment/qbittorrent' "$test_dir/actions"; then exit 1; fi

reset_state
fail_wait='flux-system/cluster-apps'
if contain_stop >"$test_dir/failed-output" 2>&1; then
  echo 'Containment continued after a failed generation wait.' >&2
  exit 1
fi
if rg -q 'scale deployment/qbit-manage|flux suspend kustomization qbit-manage' "$test_dir/actions"; then exit 1; fi

reset_state
stuck_pod=true
if contain_stop >"$test_dir/failed-output" 2>&1; then
  echo 'Containment accepted a live qbit_manage Pod.' >&2
  exit 1
fi
[[ "$replicas" == 0 ]]

reset_state
qb_ready=0
if contain_stop >"$test_dir/failed-output" 2>&1; then
  echo 'Containment claimed qBittorrent/Gluetun was ready.' >&2
  exit 1
fi
[[ "$replicas" == 0 ]]

reset_state
for key in "${!suspended[@]}"; do suspended[$key]=true; done
replicas=0
git_suspended=false
if contain_finalize >"$test_dir/failed-output" 2>&1; then
  echo 'Finalization accepted active Git source.' >&2
  exit 1
fi
if rg -q 'flux resume' "$test_dir/actions"; then exit 1; fi
if rg -q 'flux suspend' "$test_dir/actions"; then
  echo 'Finalization mutated owners before its Git precondition passed.' >&2
  exit 1
fi

git_suspended=true
artifact_revision='main@sha1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
if contain_finalize >"$test_dir/failed-output" 2>&1; then
  echo 'Finalization accepted a stale Flux artifact.' >&2
  exit 1
fi
if rg -q 'flux resume' "$test_dir/actions"; then exit 1; fi
if rg -q 'flux suspend' "$test_dir/actions"; then
  echo 'Finalization changed the owner freeze for a stale artifact.' >&2
  exit 1
fi

artifact_revision="main@sha1:$expected_revision"
contain_finalize
assert_order 'flux reconcile source git flux-system' 'flux resume kustomization flux-system' \
  'flux resume kustomization cluster-apps'
[[ "${suspended[flux-system/qbit-manage]}" == true && "${suspended[media/qbit-manage]}" == true ]]
[[ "$replicas" == 0 ]]

reset_state
for key in "${!suspended[@]}"; do suspended[$key]=true; done
replicas=0
applied_revision='main@sha1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
if contain_finalize >"$test_dir/failed-output" 2>&1; then
  echo 'Finalization accepted an owner applying the wrong revision.' >&2
  exit 1
fi
assert_order 'flux resume kustomization flux-system' 'flux suspend kustomization flux-system' \
  'flux suspend kustomization cluster-apps' 'flux suspend kustomization qbit-manage' \
  'flux suspend helmrelease qbit-manage' 'scale deployment/qbit-manage --replicas=0'
[[ "${suspended[flux-system/flux-system]}" == true && "$replicas" == 0 ]]

echo 'qbit_manage containment ordering and fail-closed fixtures passed.'
