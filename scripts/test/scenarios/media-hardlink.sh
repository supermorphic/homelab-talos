#!/usr/bin/env bash
# media-hardlink integration: proves the shared SMB filesystem preserves hardlinks and
# allows Plex to open a library name while qBittorrent holds the download name open
# (and the reverse order). Both names refer to the same test inode.
#
# It creates only a self-generated throwaway file, verifies inode identity and reads
# from the actual qBittorrent and Plex containers, then removes its test paths.
#
# This registered integration target is Lease-serialized. Cleanup is recorded separately
# from the primary assertion.
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: media-hardlink.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
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
[[ -n "$pod" ]] || { echo 'No sonarr pod found (is Sonarr deployed?).' >&2; write_recovery 'not-required' 'aborted; nothing created'; exit 3; }
qbit_pod="$(k get pod -l app.kubernetes.io/name=qbittorrent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
plex_pod="$(k get pod -l app.kubernetes.io/name=plex -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[[ -n "$qbit_pod" && -n "$plex_pod" ]] || {
  echo 'Both qBittorrent and Plex pods are required for concurrent-open testing.' >&2
  write_recovery 'not-required' 'aborted; nothing created'
  exit 3
}

holder_pid=''
cleanup() {
  local cleanup_ok=true
  if [[ -n "$holder_pid" ]]; then
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
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

# Creation and stat run in one container session, so stat sees its own writes. The
# matching inode and link counts prove the hardlink; the checks below independently
# read both names from the two application containers.
[[ -n "$src_inode" && "$src_inode" =~ ^[0-9]+$ ]] || { echo "Could not read the inode of the test file (stat output: '$stats')." >&2; exit 1; }
[[ "$src_inode" == "$dst_inode" ]] || { echo "HARDLINK BROKEN: /data/downloads and /data/media report DIFFERENT inodes ($src_inode vs $dst_inode) — an import here would COPY, not hardlink." >&2; exit 1; }
[[ "$src_links" -ge 2 && "$dst_links" -ge 2 ]] || { echo "HARDLINK BROKEN: link count < 2 (src=$src_links dst=$dst_links)." >&2; exit 1; }

echo "PRIMARY OK: same inode $src_inode across /data/downloads and /data/media, link count src=$src_links dst=$dst_links — the share preserves hardlinks; *arr imports will hardlink, not copy."

# Keep one descriptor open in a real media consumer while a separate pod opens and
# verifies the other hardlink name. A local FIFO releases the holder only after the
# other read completes. READY is emitted after the first open and content check.
concurrent_open() {
  local label="$1" holder_pod="$2" holder_path="$3" holder_mode="$4"
  local opener_pod="$5" opener_path="$6" opener_mode="$7"
  local fifo="$run_dir/${label}.fifo" holder_out="$run_dir/${label}.holder.out"
  local holder_err="$run_dir/${label}.holder.err" opener_out ready=false attempt
  mkfifo "$fifo"
  # shellcheck disable=SC2016 # The quoted script expands inside the container.
  k exec -i "$holder_pod" -c app -- sh -c '
    if [ "$3" = rw ]; then exec 3<> "$1"; else exec 3< "$1"; fi || exit 1
    content="$(cat <&3)" || exit 1
    [ "$content" = "$2" ] || exit 1
    printf "READY\n"
    IFS= read -r _
  ' sh "$holder_path" "$token" "$holder_mode" <"$fifo" >"$holder_out" 2>"$holder_err" &
  holder_pid=$!
  exec 9>"$fifo"
  for ((attempt=0; attempt<200; attempt++)); do
    if rg -qx 'READY' "$holder_out"; then ready=true; break; fi
    if ! kill -0 "$holder_pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ "$ready" != true ]]; then
    printf '\n' >&9
    exec 9>&-
    wait "$holder_pid" 2>/dev/null || true
    holder_pid=''
    echo "CONCURRENT OPEN FAILED ($label): first consumer could not open and hold its path." >&2
    return 1
  fi
  # shellcheck disable=SC2016 # The quoted script expands inside the container.
  opener_out="$(k exec "$opener_pod" -c app -- sh -c '
    if [ "$3" = rw ]; then exec 3<> "$1"; else exec 3< "$1"; fi || exit 1
    content="$(cat <&3)" || exit 1
    [ "$content" = "$2" ] || exit 1
    printf "OPEN_OK\n"
  ' sh "$opener_path" "$token" "$opener_mode")" || {
    printf '\n' >&9
    exec 9>&-
    wait "$holder_pid" 2>/dev/null || true
    holder_pid=''
    echo "CONCURRENT OPEN FAILED ($label): second consumer could not read its hardlink path." >&2
    return 1
  }
  printf '\n' >&9
  exec 9>&-
  wait "$holder_pid" || { holder_pid=''; echo "CONCURRENT OPEN FAILED ($label): holder exited with an error." >&2; return 1; }
  holder_pid=''
  [[ "$opener_out" == 'OPEN_OK' ]] || { echo "CONCURRENT OPEN FAILED ($label): unexpected read result." >&2; return 1; }
  rm -f "$fifo"
  echo "CONCURRENT OK ($label): both consumers read the same test content."
}

concurrent_open qbit-held "$qbit_pod" "$src_dir/f" rw "$plex_pod" "/Volumes/Prometheus${dst_dir#/data}/f" ro
concurrent_open plex-held "$plex_pod" "/Volumes/Prometheus${dst_dir#/data}/f" ro "$qbit_pod" "$src_dir/f" rw

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
    "dstLinkCount": (strenv(DST_LINKS) | tonumber),
    "qbitHeldPlexOpen": true,
    "plexHeldQbitOpen": true
  }' >"$run_dir/evidence.json"

echo "PASS: media-data preserves hardlinks and both concurrent-open orders (same inode $src_inode). Evidence: $run_dir"
