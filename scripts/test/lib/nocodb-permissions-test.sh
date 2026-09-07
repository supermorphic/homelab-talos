#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
source "$repo_root/scripts/test/lib/nocodb-permissions.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/nocodb-permissions-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/bin"
target="$fixture/target"
touch "$target"
log="$fixture/stat.log"

cat >"$fixture/bin/uname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 1 && "$1" == -s ]] || exit 64
[[ "${NOCODB_TEST_UNAME_STATUS:-0}" -eq 0 ]] || exit "$NOCODB_TEST_UNAME_STATUS"
printf '%s\n' "${NOCODB_TEST_PLATFORM:?}"
EOF

cat >"$fixture/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${NOCODB_TEST_STAT_LOG:?}"
printf '%s\n' "${NOCODB_TEST_STAT_OUTPUT:?}"
[[ "${NOCODB_TEST_STAT_STATUS:-0}" -eq 0 ]] || exit "$NOCODB_TEST_STAT_STATUS"
EOF
chmod 700 "$fixture/bin/uname" "$fixture/bin/stat"

export NOCODB_TEST_STAT_LOG="$log"
OUT=''
STATUS=0
run_mode() {
	set +e
	OUT="$(PATH="$fixture/bin:$PATH" nocodb_test_mode "$target" 2>"$fixture/stderr")"
	STATUS="$?"
	set -e
}

: >"$log"
export NOCODB_TEST_PLATFORM=Linux NOCODB_TEST_STAT_OUTPUT=700
run_mode
[[ "$OUT" == 700 && "$STATUS" -eq 0 ]]
[[ "$(cat "$log")" == "-c %a $target" ]]

: >"$log"
export NOCODB_TEST_PLATFORM=Darwin NOCODB_TEST_STAT_OUTPUT=600
run_mode
[[ "$OUT" == 600 && "$STATUS" -eq 0 ]]
[[ "$(cat "$log")" == "-f %Lp $target" ]]

: >"$log"
export NOCODB_TEST_PLATFORM=Linux NOCODB_TEST_STAT_OUTPUT=700 NOCODB_TEST_STAT_STATUS=73
run_mode
[[ -z "$OUT" && "$STATUS" -eq 73 ]]
[[ "$(wc -l <"$log" | tr -d ' ')" -eq 1 ]]
unset NOCODB_TEST_STAT_STATUS

: >"$log"
export NOCODB_TEST_UNAME_STATUS=74
run_mode
[[ -z "$OUT" && "$STATUS" -eq 74 && ! -s "$log" ]]
unset NOCODB_TEST_UNAME_STATUS

: >"$log"
export NOCODB_TEST_PLATFORM=Plan9
run_mode
[[ -z "$OUT" && "$STATUS" -eq 1 && ! -s "$log" ]]
rg -Fxq 'NocoDB test permissions: unsupported platform: Plan9.' "$fixture/stderr"

echo 'NocoDB permission portability tests passed.'
