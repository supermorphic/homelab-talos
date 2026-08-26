#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: ntfy-publish.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
expected_confirmation='test:ntfy:publish:media-critical-homelab'
[[ "${NTFY_PUBLISH_TEST_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing positive ntfy publish test; set NTFY_PUBLISH_TEST_CONFIRM='$expected_confirmation'." >&2
  exit 1
}

scripts/verify/ntfy.sh "$kubeconfig"

ns='ntfy'
base_url='https://ntfy.lab.supermorphic.com'
kc=(kubectl --kubeconfig "$kubeconfig")
if "${kc[@]}" config get-contexts homelab-diagnostic --no-headers >/dev/null 2>&1; then
  kc+=(--context homelab-diagnostic)
fi

# Read the already-provisioned producer tokens without printing them. Keep the
# Authorization header and message body out of the curl process command line.
# shellcheck disable=SC2016 # Variables expand in the remote container.
tokens="$("${kc[@]}" --namespace "$ns" exec deployment/ntfy -c app -- \
  sh -c 'printf %s "$NTFY_AUTH_TOKENS"')"
token_for() {
  awk -F, -v user="$1" \
    '{for (i=1; i<=NF; i++) {n=split($i,a,":"); if (a[1]==user) {print a[2]; exit}}}' \
    <<<"$tokens"
}
seerr_token="$(token_for seerr)"
alertmanager_token="$(token_for alertmanager)"
[[ -n "$seerr_token" && -n "$alertmanager_token" ]] || {
  echo 'Could not read the expected seerr and alertmanager tokens.' >&2
  exit 1
}

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-ntfy-publish-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
publish() {
  local producer="$1" token="$2" topic="$3" config response
  config="$temp_dir/$topic.curl"
  {
    printf '%s\n' 'silent' 'show-error' 'output = "/dev/null"' \
      'write-out = "%{http_code}"' 'max-time = 15' 'request = "POST"'
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Title: ntfy publish test"\n'
    printf 'data = "%s->%s positive ACL test"\n' "$producer" "$topic"
    printf 'url = "%s/%s"\n' "$base_url" "$topic"
  } >"$config"
  response="$(curl --config "$config")"
  [[ "$response" == '200' ]] || {
    echo "$producer could not publish the positive ACL test to $topic." >&2
    exit 1
  }
  echo "ntfy positive ACL passed: $producer -> $topic."
}

publish seerr "$seerr_token" media
publish alertmanager "$alertmanager_token" critical
publish alertmanager "$alertmanager_token" homelab
echo 'ntfy positive publish test passed; three test notifications were delivered.'
