#!/usr/bin/env bash
set -euo pipefail
umask 077

git_bin="${GIT_BIN:-git}"
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

main_talosconfig="$main_clone_root/.talos/config"
worktree_talosconfig="$worktree_root/.talos/config"
[[ -f "$main_talosconfig" ]] || {
  echo "Missing main-clone .talos/config at $main_talosconfig; ask the operator to restore Talos admin access there first." >&2
  exit 1
}

talosconfig_dir="${worktree_talosconfig%/*}"
install -d -m 700 "$talosconfig_dir"
[[ ! -e "$talosconfig_dir/config.rollback" ]] || {
  echo 'RECOVERY REQUIRED: resolve the prior Talos config.rollback before installing a reader credential.' >&2
  exit 1
}
staged_talosconfig=''
trap '[[ -z "$staged_talosconfig" ]] || rm -f -- "$staged_talosconfig"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
staged_talosconfig="$("$mktemp_bin" "$talosconfig_dir/config.XXXXXX")"
# talosctl config new requires an absent output path in this private directory.
rm -f -- "$staged_talosconfig"
"$talosctl_bin" config new "$staged_talosconfig" --roles os:reader --crt-ttl 2160h \
  --talosconfig "$main_talosconfig" --nodes 192.168.90.10 \
  --endpoints 192.168.90.10,192.168.90.11,192.168.90.12
[[ -s "$staged_talosconfig" ]] || {
  echo 'Refusing staged Talos config: os:reader credential generation produced no output.' >&2
  exit 1
}
chmod 600 "$staged_talosconfig"
# A single same-directory rename preserves the prior file if publication fails.
"$mv_bin" -f -- "$staged_talosconfig" "$worktree_talosconfig"
echo "Wrote Talos reader credential for worktree $worktree_root."
