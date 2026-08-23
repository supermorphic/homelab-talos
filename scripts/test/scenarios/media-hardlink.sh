#!/usr/bin/env bash
# media-hardlink integration: proves the shared media-data SMB filesystem preserves HARDLINKS
# across the /data/downloads <-> /data/media subtrees — the exact filesystem property the
# Servarr "Use Hardlinks instead of Copy" import depends on. If this ever breaks (SMB
# remount options change; downloads/media land on different filesystems), every *arr import
# would silently fall back to a full COPY and double media storage.
#
# Deterministic + safe: it creates a self-generated throwaway file (no external download, no
# real content, no legal concern), hardlinks it across the two subtrees, asserts both paths
# report the SAME inode with link count >= 2 (the storage contract in
# docs/specs/006-media-stack-architecture.md), then removes the test files. It does NOT touch real media.
#
# This integration target is operator-only + Lease-serialized but needs no chaos token
# (it is non-destructive to real data). A focused filesystem runner, so it lives under
# scripts/test/scenarios/. Cleanup is recorded separately from the primary assertion.
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: media-hardlink.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
# Any media pod that mounts the media-data share at /data works; sonarr is stable + does.
selector='app.kubernetes.io/name=sonarr'

run_dir="${HOMELAB_TEST_RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  mkdir -p "$repo_root/.test-results"
  run_dir="$(mktemp -d "$repo_root/.test-results/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=12 HEAD)-media-hardlink.XXXXXX")"
fi
run_id="$(basename "$run_dir" | tr -cd 'A-Za-z0-9')"
src_dir="/data/downloads/.e2e-media-hardlink-${run_id}"
dst_dir="/data/media/.e2e-media-hardlink-${run_id}"
token="hardlink-${run_id}-$$"
write_recovery() { printf '{"status":"%s","reason":"%s"}\n' "$1" "$2" >"$run_dir/recovery.json"; }
write_recovery 'not-attempted' 'orchestrator started'

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
app_exec() { k exec "$1" -c app -- sh -c "$2"; }

pod="$(k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$pod" ]] || { echo 'No sonarr pod found (is Phase 13 bootstrapped?).' >&2; write_recovery 'not-required' 'aborted; nothing created'; exit 3; }

cleanup() {
  local cleanup_ok=true
  app_exec "$pod" "rm -rf '$src_dir' '$dst_dir'" >/dev/null 2>&1 || cleanup_ok=false
  if [[ "$cleanup_ok" == true ]]; then write_recovery 'passed' 'test hardlink pair removed from the share'
  else write_recovery 'failed' "could not remove test dirs $src_dir / $dst_dir — remove manually"; fi
}
trap cleanup EXIT

# Create the download-side file and hardlink it into the media-side subtree, then stat both.
# Output: "<src_inode> <src_links>|<dst_inode> <dst_links>".
echo "Creating a self-generated file under $src_dir and hardlinking it into $dst_dir (share: media-data)."
stats="$(app_exec "$pod" "
  set -e
  mkdir -p '$src_dir' '$dst_dir'
  printf '%s' '$token' > '$src_dir/f'
  ln '$src_dir/f' '$dst_dir/f'
  printf '%s|%s' \"\$(stat -c '%i %h' '$src_dir/f')\" \"\$(stat -c '%i %h' '$dst_dir/f')\"
")"
src_inode="${stats%%|*}"; src_links="${src_inode#* }"; src_inode="${src_inode%% *}"
dst_field="${stats##*|}"; dst_inode="${dst_field%% *}"; dst_links="${dst_field#* }"

# The create+hardlink+stat all ran in ONE in-container session above, so the stat sees its
# own writes (robust). Same inode across the two subtrees IS the hardlink proof — the two
# paths are the same file, so content is identical by definition (no separate cross-session
# read needed; that would be subject to SMB read-after-write lag).
[[ -n "$src_inode" && "$src_inode" =~ ^[0-9]+$ ]] || { echo "Could not read the inode of the test file (stat output: '$stats')." >&2; exit 1; }
[[ "$src_inode" == "$dst_inode" ]] || { echo "HARDLINK BROKEN: /data/downloads and /data/media report DIFFERENT inodes ($src_inode vs $dst_inode) — an import here would COPY, not hardlink." >&2; exit 1; }
[[ "$src_links" -ge 2 && "$dst_links" -ge 2 ]] || { echo "HARDLINK BROKEN: link count < 2 (src=$src_links dst=$dst_links)." >&2; exit 1; }

echo "PRIMARY OK: same inode $src_inode across /data/downloads and /data/media, link count src=$src_links dst=$dst_links — the share preserves hardlinks; *arr imports will hardlink, not copy."

RUN_POD="$pod" SRC_DIR="$src_dir" DST_DIR="$dst_dir" SRC_INODE="$src_inode" DST_INODE="$dst_inode" \
SRC_LINKS="$src_links" DST_LINKS="$dst_links" \
  yq --null-input --output-format json '{
    "target": "media-hardlink",
    "probePod": strenv(RUN_POD),
    "srcPath": (strenv(SRC_DIR) + "/f"),
    "dstPath": (strenv(DST_DIR) + "/f"),
    "srcInode": (strenv(SRC_INODE) | tonumber),
    "dstInode": (strenv(DST_INODE) | tonumber),
    "sameInode": (strenv(SRC_INODE) == strenv(DST_INODE)),
    "srcLinkCount": (strenv(SRC_LINKS) | tonumber),
    "dstLinkCount": (strenv(DST_LINKS) | tonumber)
  }' >"$run_dir/evidence.json"

echo "PASS: media-data preserves hardlinks across downloads<->media (same inode $src_inode). Evidence: $run_dir"
