#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$repo_root/scripts/test/lib/monitoring-fixtures.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/monitoring-fixtures-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

fixture_digest() {
	find "$1" -type f -exec cksum {} + | LC_ALL=C sort
}

expect_rejected() {
	local relative="$1"
	if monitoring_fixture_reset "$fixture/template" "$fixture/case" "$relative"; then
		echo "expected fixture reset to reject: $relative" >&2
		exit 1
	fi
}

mkdir -p "$fixture/repository/kubernetes/example" \
	"$fixture/repository/scripts" "$fixture/repository/tests" "$fixture/bin"
printf 'creation_rules: []\n' >"$fixture/repository/.sops.yaml"
printf 'original\n' >"$fixture/repository/kubernetes/example/values.yaml"
printf '#!/usr/bin/env bash\n' >"$fixture/repository/scripts/example.sh"
printf 'fixture\n' >"$fixture/repository/tests/example.yaml"
ln -s values.yaml "$fixture/repository/kubernetes/example/symlink.yaml"

monitoring_fixture_prepare "$fixture/repository" "$fixture/template" "$fixture/case"
canonical_template="$(cd -P -- "$fixture/template" && pwd)"
cmp "$fixture/template/.sops.yaml" "$fixture/case/.sops.yaml"
cmp "$fixture/template/kubernetes/example/values.yaml" \
	"$fixture/case/kubernetes/example/values.yaml"
cmp "$fixture/template/scripts/example.sh" "$fixture/case/scripts/example.sh"
cmp "$fixture/template/tests/example.yaml" "$fixture/case/tests/example.yaml"

before="$(fixture_digest "$fixture/template")"
printf 'mutation\n' >>"$fixture/case/kubernetes/example/values.yaml"
monitoring_fixture_reset "$fixture/template" "$fixture/case" \
	kubernetes/example/values.yaml
cmp "$fixture/template/kubernetes/example/values.yaml" \
	"$fixture/case/kubernetes/example/values.yaml"
[[ "$before" == "$(fixture_digest "$fixture/template")" ]]

expect_rejected '../escape'
expect_rejected '/absolute'
expect_rejected 'kubernetes/example'
expect_rejected 'kubernetes/example/missing.yaml'
expect_rejected 'kubernetes/example/symlink.yaml'

# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
	'case "${1:-}" in' \
	'  -f) [[ "${2:-}" == "%Lp" ]] || exit 2 ;;' \
	'  -c) [[ "${2:-}" == "%a" ]] || exit 2 ;;' \
	'  *) exit 2 ;;' \
	'esac' \
	'printf "%s\\n" "$*" >>"$FAKE_STAT_LOG"' \
	'printf "%s\\n" 640' >"$fixture/bin/stat"
chmod +x "$fixture/bin/stat"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
	'printf "%s\\n" "$FIXTURE_UNAME"' >"$fixture/bin/uname"
chmod +x "$fixture/bin/uname"

for fixture_uname in Darwin Linux; do
	stat_log="$fixture/$fixture_uname-stat.log"
	PATH="$fixture/bin:$PATH" FIXTURE_UNAME="$fixture_uname" \
		FAKE_STAT_LOG="$stat_log" \
		monitoring_fixture_reset "$fixture/template" "$fixture/case" \
		kubernetes/example/values.yaml
	if [[ "$fixture_uname" == Darwin ]]; then
		[[ "$(<"$stat_log")" == "-f %Lp $canonical_template/kubernetes/example/values.yaml" ]]
	else
		[[ "$(<"$stat_log")" == "-c %a $canonical_template/kubernetes/example/values.yaml" ]]
	fi
done

rm "$fixture/case/kubernetes/example/values.yaml"
mkdir "$fixture/case/kubernetes/example/values.yaml"
expect_rejected 'kubernetes/example/values.yaml'

echo 'Monitoring fixture helper tests passed.'
