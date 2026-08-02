#!/usr/bin/env bash
set -euo pipefail
umask 077

git_bin="${GIT_BIN:-git}"
kubectl_bin="${KUBECTL_BIN:-kubectl}"
talosctl_bin="${TALOSCTL_BIN:-talosctl}"
mktemp_bin="${MKTEMP_BIN:-mktemp}"
mv_bin="${MV_BIN:-mv}"

worktree_root="$("$git_bin" rev-parse --show-toplevel)"
git_common_dir="$("$git_bin" rev-parse --path-format=absolute --git-common-dir)"

[[ "$worktree_root" == /* ]] || {
  echo "Refusing credential install: Git returned a non-absolute worktree root: $worktree_root" >&2
  exit 1
}
[[ "$git_common_dir" == /* ]] || {
  echo "Refusing credential install: Git returned a non-absolute common directory: $git_common_dir" >&2
  exit 1
}
[[ -d "$git_common_dir" ]] || {
  echo "Refusing credential install: Git common directory does not exist: $git_common_dir" >&2
  exit 1
}

worktree_root="$(cd -- "$worktree_root" && pwd -P)"
git_common_dir="$(cd -- "$git_common_dir" && pwd -P)"
main_clone_root="$(cd -- "$(dirname -- "$git_common_dir")" && pwd -P)"

[[ "$worktree_root" != "$main_clone_root" ]] || {
  echo 'Refusing scoped credential install in the main clone; use the Talos admin download path.' >&2
  exit 1
}

main_kubeconfig="$main_clone_root/.kube/config"
main_talosconfig="$main_clone_root/.talos/config"
worktree_kubeconfig="$worktree_root/.kube/config"
worktree_talosconfig="$worktree_root/.talos/config"

[[ -f "$main_kubeconfig" ]] || {
  echo "Missing main-clone .kube/config at $main_kubeconfig; ask the operator to restore admin access there first." >&2
  exit 1
}
[[ -f "$main_talosconfig" ]] || {
  echo "Missing main-clone .talos/config at $main_talosconfig; ask the operator to restore admin access there first." >&2
  exit 1
}

kubeconfig_dir="${worktree_kubeconfig%/*}"
talosconfig_dir="${worktree_talosconfig%/*}"
install -d -m 700 "$kubeconfig_dir" "$talosconfig_dir"
staged_kubeconfig=''
staged_talosconfig=''
backup_kubeconfig=''
backup_talosconfig=''
cleanup() {
  local temp_file
  for temp_file in \
    "$staged_kubeconfig" \
    "$staged_talosconfig" \
    "$backup_kubeconfig" \
    "$backup_talosconfig"; do
    [[ -z "$temp_file" ]] || rm -f -- "$temp_file"
  done
}
trap cleanup EXIT
staged_kubeconfig="$("$mktemp_bin" "$kubeconfig_dir/config.XXXXXX")"
staged_talosconfig="$("$mktemp_bin" "$talosconfig_dir/config.XXXXXX")"

api_server="$("$kubectl_bin" --kubeconfig "$main_kubeconfig" config view --raw \
  --output "jsonpath={.clusters[0].cluster.server}")"
ca_data="$("$kubectl_bin" --kubeconfig "$main_kubeconfig" config view --raw \
  --output "jsonpath={.clusters[0].cluster.certificate-authority-data}")"
[[ "$api_server" == 'https://192.168.90.20:6443' ]] || {
  echo "Refusing main-clone kubeconfig: server $api_server is not the expected API VIP https://192.168.90.20:6443." >&2
  exit 1
}
[[ -n "$ca_data" && "$ca_data" != 'null' && "$ca_data" != *$'\n'* ]] || {
  echo 'Refusing main-clone kubeconfig: embedded Kubernetes CA data is missing or invalid.' >&2
  exit 1
}

observer_token="$("$kubectl_bin" --kubeconfig "$main_kubeconfig" --namespace kube-system \
  create token homelab-observer --duration=720h)"
diagnostic_token="$("$kubectl_bin" --kubeconfig "$main_kubeconfig" --namespace kube-system \
  create token homelab-diagnostic --duration=720h)"
[[ -n "$observer_token" && "$observer_token" != *$'\n'* ]] || {
  echo 'Refusing observer credential: token output is empty or malformed.' >&2
  exit 1
}
[[ -n "$diagnostic_token" && "$diagnostic_token" != *$'\n'* ]] || {
  echo 'Refusing diagnostic credential: token output is empty or malformed.' >&2
  exit 1
}

cat >"$staged_kubeconfig" <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: $api_server
      certificate-authority-data: $ca_data
contexts:
  - name: homelab-observer
    context:
      cluster: homelab
      user: homelab-observer
  - name: homelab-diagnostic
    context:
      cluster: homelab
      user: homelab-diagnostic
current-context: homelab-observer
users:
  - name: homelab-observer
    user:
      token: $observer_token
  - name: homelab-diagnostic
    user:
      token: $diagnostic_token
YAML
chmod 600 "$staged_kubeconfig"

"$talosctl_bin" config new "$staged_talosconfig" --roles os:reader --crt-ttl 2160h \
  --talosconfig "$main_talosconfig" --nodes 192.168.90.10 \
  --endpoints 192.168.90.10,192.168.90.11,192.168.90.12
chmod 600 "$staged_talosconfig"

staged_api_server="$("$kubectl_bin" --kubeconfig "$staged_kubeconfig" config view --raw \
  --output "jsonpath={.clusters[0].cluster.server}")"
staged_contexts="$("$kubectl_bin" --kubeconfig "$staged_kubeconfig" config view --raw \
  --output 'jsonpath={range .contexts[*]}{.name}{"\n"}{end}' | LC_ALL=C sort)"
staged_users="$("$kubectl_bin" --kubeconfig "$staged_kubeconfig" config view --raw \
  --output 'jsonpath={range .users[*]}{.name}{"\n"}{end}' | LC_ALL=C sort)"
staged_current_context="$("$kubectl_bin" --kubeconfig "$staged_kubeconfig" config view --raw \
  --output 'jsonpath={.current-context}')"
staged_observer_token="$("$kubectl_bin" --kubeconfig "$staged_kubeconfig" config view --raw \
  --output 'jsonpath={.users[?(@.name == "homelab-observer")].user.token}')"
staged_diagnostic_token="$("$kubectl_bin" --kubeconfig "$staged_kubeconfig" config view --raw \
  --output 'jsonpath={.users[?(@.name == "homelab-diagnostic")].user.token}')"

[[ "$staged_api_server" == 'https://192.168.90.20:6443' ]] || {
  echo 'Refusing staged kubeconfig: API VIP validation failed.' >&2
  exit 1
}
[[ "$staged_contexts" == $'homelab-diagnostic\nhomelab-observer' ]] || {
  echo 'Refusing staged kubeconfig: expected exactly observer and diagnostic contexts.' >&2
  exit 1
}
[[ "$staged_users" == $'homelab-diagnostic\nhomelab-observer' ]] || {
  echo 'Refusing staged kubeconfig: expected exactly observer and diagnostic users.' >&2
  exit 1
}
[[ "$staged_current_context" == 'homelab-observer' ]] || {
  echo 'Refusing staged kubeconfig: observer must be the current context.' >&2
  exit 1
}
[[ "$staged_observer_token" == "$observer_token" && "$staged_diagnostic_token" == "$diagnostic_token" ]] || {
  echo 'Refusing staged kubeconfig: minted scoped tokens were not installed correctly.' >&2
  exit 1
}
[[ -s "$staged_talosconfig" ]] || {
  echo 'Refusing staged Talos config: os:reader credential generation produced no output.' >&2
  exit 1
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}
[[ "$(file_mode "$staged_kubeconfig")" == '600' && "$(file_mode "$staged_talosconfig")" == '600' ]] || {
  echo 'Refusing staged credentials: both files must have mode 0600.' >&2
  exit 1
}

kubeconfig_existed=false
talosconfig_existed=false
if [[ -e "$worktree_kubeconfig" ]]; then
  kubeconfig_existed=true
  backup_kubeconfig="$("$mktemp_bin" "$kubeconfig_dir/config.backup.XXXXXX")"
  install -m 600 "$worktree_kubeconfig" "$backup_kubeconfig"
fi
if [[ -e "$worktree_talosconfig" ]]; then
  talosconfig_existed=true
  backup_talosconfig="$("$mktemp_bin" "$talosconfig_dir/config.backup.XXXXXX")"
  install -m 600 "$worktree_talosconfig" "$backup_talosconfig"
fi

rollback_prior_pair() {
  local rollback_status=0

  if [[ "$kubeconfig_existed" == true ]]; then
    "$mv_bin" -f -- "$backup_kubeconfig" "$worktree_kubeconfig" || rollback_status=1
  else
    rm -f -- "$worktree_kubeconfig" || rollback_status=1
  fi

  if [[ "$talosconfig_existed" == true ]]; then
    "$mv_bin" -f -- "$backup_talosconfig" "$worktree_talosconfig" || rollback_status=1
  else
    rm -f -- "$worktree_talosconfig" || rollback_status=1
  fi

  return "$rollback_status"
}

# Each replacement is an atomic same-directory rename. If either ordinary move
# command fails, restore the complete prior pair; a crash-safe transaction across
# the two credential directories is outside the filesystem's guarantees.
if ! "$mv_bin" -f -- "$staged_kubeconfig" "$worktree_kubeconfig"; then
  rollback_prior_pair || {
    echo 'Credential publication failed and rollback could not restore the prior pair.' >&2
    exit 1
  }
  echo 'Credential publication failed before replacing the kubeconfig; restored the prior pair.' >&2
  exit 1
fi
if ! "$mv_bin" -f -- "$staged_talosconfig" "$worktree_talosconfig"; then
  rollback_prior_pair || {
    echo 'Credential publication failed and rollback could not restore the prior pair.' >&2
    exit 1
  }
  echo 'Credential publication failed while replacing the Talos config; restored the prior pair.' >&2
  exit 1
fi

cleanup
trap - EXIT
echo "Wrote scoped Kubernetes and Talos credentials for worktree $worktree_root."
