#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
runner="$repo_root/scripts/test/lib/harness-shell-runner.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-shell-runner-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin" "$fixture_root/fragments"

write_result_case_junit() {
	local output_file="$1" suite_name="$2" case_name="$3" result="$4" duration="$5"
	printf '<testsuite name="%s"><testcase classname="%s" name="%s" time="%s">' \
		"$suite_name" "$suite_name" "$case_name" "$duration" >"$output_file"
	case "$result" in
	failed) printf '<failure/>' >>"$output_file" ;;
	skipped) printf '<skipped/>' >>"$output_file" ;;
	esac
	printf '</testcase></testsuite>\n' >>"$output_file"
}

# shellcheck source=scripts/test/lib/harness-shell-runner.sh
source "$runner"

cat >"$fixture_root/bin/barrier" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$1"
printf '%s\n' "$name" >"${BARRIER_ROOT:?}/$name.started"
deadline=$((SECONDS + 5))
until [[ -e "$BARRIER_ROOT/first.started" && -e "$BARRIER_ROOT/second.started" ]]; do
	((SECONDS < deadline)) || exit 70
	sleep 0.01
done
printf '%s=%s\n' "$name" "${TMPDIR:?}" >>"${TMP_PATH_LOG:?}"
[[ -d "$TMPDIR" ]]
[[ -z "${TEST_RESULT_FRAGMENT_DIR+x}" ]]
[[ -z "${TEST_SHARED_RESULT_DIR+x}" ]]
[[ -z "${TEST_RUN_ID+x}" ]]
[[ "$name" != first ]] || sleep 0.8
printf '%s\n' "$name" >>"${TMP_LOG:?}"
printf 'output-%s\n' "$name"
EOF
cat >"$fixture_root/bin/third" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -e "${BARRIER_ROOT:?}/first.started" && -e "$BARRIER_ROOT/second.started" ]]
printf '%s\n' third >>"${TMP_LOG:?}"
printf '%s=%s\n' third "${TMPDIR:?}" >>"${TMP_PATH_LOG:?}"
printf 'output-third\n'
EOF
cat >"$fixture_root/bin/blocking" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'printf terminated >"${TERMINATED_MARKER:?}"; exit 143' TERM INT
printf started >"${BLOCKING_MARKER:?}"
while :; do sleep 0.05; done
EOF
chmod +x "$fixture_root/bin/"*

export BARRIER_ROOT="$fixture_root/barrier"
export TMP_LOG="$fixture_root/order.log"
export TMP_PATH_LOG="$fixture_root/tmp-paths.log"
export TEST_RESULT_FRAGMENT_DIR=outer-fragments
export TEST_SHARED_RESULT_DIR=outer-shared
export TEST_RUN_ID=outer-run
mkdir "$BARRIER_ROOT"

register_harness_shell_case first "$fixture_root/bin/barrier" first
register_harness_shell_case second "$fixture_root/bin/barrier" second
register_harness_shell_case third "$fixture_root/bin/third"
run_registered_harness_shell_cases "$fixture_root/fragments" 2 0 \
	>"$fixture_root/output.log" 2>&1

[[ "$(cat "$fixture_root/output.log")" == $'output-first\noutput-second\noutput-third' ]]
[[ "$(cat "$TMP_LOG")" == $'second\nthird\nfirst' ]]
for index in 1 2 3; do
	fragment="$fixture_root/fragments/bash-${index}.xml"
	[[ -s "$fragment" ]]
	case_name="$(sed -n 's/.*name="\([^"]*\)" time=.*/\1/p' "$fragment")"
	[[ "$case_name" == "$(
		sed -n "${index}p" <<'EOF'
first
second
third
EOF
	)" ]]
	case_time="$(sed -n 's/.*time="\([^"]*\)".*/\1/p' "$fragment")"
	awk -v value="$case_time" 'BEGIN { exit !(value >= 0) }'
done
mapfile -t tmp_paths < <(cut -d= -f2- "$TMP_PATH_LOG" | LC_ALL=C sort -u)
[[ "${#tmp_paths[@]}" -eq 3 ]]

for invalid in 0 9 abc ''; do
	marker="$fixture_root/invalid-${invalid:-empty}"
	reset_harness_shell_cases
	register_harness_shell_case marker touch "$marker"
	set +e
	run_registered_harness_shell_cases "$fixture_root/fragments" "$invalid" 0 >/dev/null 2>&1
	status="$?"
	set -e
	[[ "$status" -ne 0 && ! -e "$marker" ]]
done
reset_harness_shell_cases
register_harness_shell_case duplicate true
if register_harness_shell_case duplicate true 2>/dev/null; then exit 1; fi
if register_harness_shell_case Bad true 2>/dev/null; then exit 1; fi
if register_harness_shell_case empty 2>/dev/null; then exit 1; fi

reset_harness_shell_cases
rm -f "$fixture_root/fragments"/*.xml
export BLOCKING_MARKER="$fixture_root/blocking.started"
export TERMINATED_MARKER="$fixture_root/blocking.terminated"
tail_marker="$fixture_root/tail.started"
# shellcheck disable=SC2016 # The child shell expands its inherited marker path.
register_harness_shell_case quick-failure bash -c \
	'until [[ -e "$BLOCKING_MARKER" ]]; do sleep 0.01; done; exit 23'
register_harness_shell_case blocking "$fixture_root/bin/blocking"
register_harness_shell_case never-started touch "$tail_marker"
set +e
run_registered_harness_shell_cases "$fixture_root/fragments" 2 0 \
	>"$fixture_root/failure-output.log" 2>&1
status="$?"
set -e
[[ "$status" -eq 23 ]]
[[ -e "$BLOCKING_MARKER" && -e "$TERMINATED_MARKER" ]]
[[ ! -e "$tail_marker" ]]
[[ -s "$fixture_root/fragments/bash-1.xml" ]]
[[ -s "$fixture_root/fragments/bash-2.xml" ]]
rg -q '<failure/>' "$fixture_root/fragments/bash-1.xml"
rg -q '<skipped/>' "$fixture_root/fragments/bash-2.xml"
[[ ! -e "$fixture_root/fragments/bash-3.xml" ]]
if pgrep -f "$fixture_root/bin/blocking" >/dev/null; then
	echo 'Canceled harness worker remains active.' >&2
	exit 1
fi

echo 'Harness shell runner tests passed.'
