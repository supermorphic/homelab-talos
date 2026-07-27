#!/bin/sh
# Install one publisher-generated, checksummed bundle and swap the state generation
# last. TEST_REPORTS_STORAGE_ROOT makes this script independently testable offline.
set -eu

run_id="${1:-}"
generation="${2:-}"
storage_root="${TEST_REPORTS_STORAGE_ROOT:-/srv}"

valid_run_id() {
  case "$1" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-agent-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f] | \
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-github-actions-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f] | \
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-operator-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
    *) return 1 ;;
  esac
}
valid_run_id "$run_id" || {
  echo "Unsafe run ID: $run_id" >&2
  exit 2
}
case "$generation" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) echo "Unsafe generation ID: $generation" >&2; exit 2 ;;
esac

stage="$storage_root/.publish-$generation"
archive="$storage_root/.publish-$generation.tar"
cleanup() {
  rm -rf -- "$stage"
  rm -f -- "$archive"
}
trap cleanup EXIT HUP INT TERM
rm -rf -- "$stage"
rm -f -- "$archive"
mkdir -p "$stage"
cat >"$archive"
tar -tf "$archive" |
  while IFS= read -r member; do
    case "$member" in
      /* | ../* | */../* | */..) echo "Unsafe archive member: $member" >&2; exit 1 ;;
    esac
  done
tar -xf "$archive" -C "$stage"

expected_root=$(printf '%s\n' artifact generation manifest.sha256 prune.txt report)
actual_root=$(find "$stage" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
[ "$actual_root" = "$expected_root" ] || {
  echo 'Publication bundle has unexpected top-level entries.' >&2
  exit 1
}
if find "$stage" -type l -print -quit | grep -q .; then
  echo 'Publication bundle must not contain symlinks.' >&2
  exit 1
fi
artifact_root=$(find "$stage/artifact" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
report_root=$(find "$stage/report" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
generation_root=$(find "$stage/generation" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
[ "$artifact_root" = "$run_id.tar.gz" ]
[ "$report_root" = "$run_id" ]
[ "$generation_root" = "$generation" ]

computed_manifest="$stage/manifest.computed"
(
  cd "$stage"
  find artifact generation report prune.txt -type f -print |
    sort |
    while IFS= read -r path; do
      sha256sum "$path"
    done
) >"$computed_manifest"
cmp -s "$computed_manifest" "$stage/manifest.sha256" || {
  echo 'Publication bundle checksum manifest does not match its exact file set.' >&2
  exit 1
}
rm -f -- "$computed_manifest"

[ -d "$stage/report/$run_id/awesome" ]
[ -f "$stage/report/$run_id/awesome/index.html" ]
[ -f "$stage/artifact/$run_id.tar.gz" ]
[ -d "$stage/generation/$generation" ]
[ -f "$stage/generation/$generation/catalog.json" ]
[ -f "$stage/generation/$generation/state.json" ]
[ -f "$stage/generation/$generation/index.html" ]

# Validate the entire retention list before making any persistent changes.
while IFS= read -r stale_run; do
  [ -n "$stale_run" ] || continue
  valid_run_id "$stale_run" || {
    echo "Unsafe prune run ID: $stale_run" >&2
    exit 1
  }
done <"$stage/prune.txt"

mkdir -p "$storage_root/reports" "$storage_root/artifacts" "$storage_root/state/generations"
rm -rf -- "$storage_root/reports/$run_id" "$storage_root/artifacts/$run_id.tar.gz"
mv "$stage/report/$run_id" "$storage_root/reports/$run_id"
mv "$stage/artifact/$run_id.tar.gz" "$storage_root/artifacts/$run_id.tar.gz"
rm -rf -- "$storage_root/state/generations/$generation"
mv "$stage/generation/$generation" "$storage_root/state/generations/$generation"

while IFS= read -r stale_run; do
  [ -n "$stale_run" ] || continue
  rm -rf -- "$storage_root/reports/$stale_run"
  rm -f -- "$storage_root/artifacts/$stale_run.tar.gz"
done <"$stage/prune.txt"

ln -s "generations/$generation" "$storage_root/state/current.next"
# BSD mv uses -h and BusyBox mv uses -T to replace a symlink without following
# its directory target. Both operations are a same-filesystem atomic rename.
if ! mv -fh "$storage_root/state/current.next" "$storage_root/state/current" 2>/dev/null; then
  mv -Tf "$storage_root/state/current.next" "$storage_root/state/current"
fi

find "$storage_root/state/generations" -mindepth 1 -maxdepth 1 -type d \
  ! -name "$generation" ! -name bootstrap -exec rm -rf -- {} \;
trap - EXIT HUP INT TERM
rm -rf -- "$stage"
rm -f -- "$archive"
