#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/agent-access.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/agent-access-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig" "$fixture/talosconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ " $* " == *' config get-contexts '* ]]; then
  context=''
  for argument in "$@"; do
    [[ "$argument" != homelab-* ]] || context="$argument"
  done
  case "${FAKE_LAYOUT}:${context}" in
    named:homelab-observer|named:homelab-diagnostic|partial:homelab-observer) exit 0 ;;
    *) exit 1 ;;
  esac
fi

[[ " $* " == *' auth can-i '* ]] || {
  echo "unexpected kubectl call: $*" >&2
  exit 64
}
printf '%q ' "$@" >>"$FAKE_CALL_LOG"
printf '\n' >>"$FAKE_CALL_LOG"

args=("$@")
verb=''
resource=''
diagnostic=false
for ((index = 0; index < ${#args[@]}; index++)); do
  case "${args[$index]}" in
    --context|--as)
      identity="${args[$((index + 1))]}"
      [[ "$identity" != *homelab-diagnostic ]] || diagnostic=true
      ;;
    --context=*|--as=*)
      [[ "${args[$index]}" != *homelab-diagnostic ]] || diagnostic=true
      ;;
    can-i)
      verb="${args[$((index + 1))]}"
      resource="${args[$((index + 2))]}"
      ;;
  esac
done

answer=yes
case "$verb:$resource" in
  create:pods/exec|create:pods/portforward)
    [[ "$diagnostic" == true ]] || answer=no
    ;;
  get:secrets|create:*|patch:*|delete:*|bind:*|escalate:*|impersonate:*) answer=no ;;
esac
printf '%s\n' "$answer"
EOF
chmod +x "$fixture/bin/kubectl"

cat >"$fixture/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == version || "$1" == services ]] || exit 64
EOF
chmod +x "$fixture/bin/talosctl"

run_layout() {
  local layout="$1"
  local log="$fixture/$layout.log"
  : >"$log"
  PATH="$fixture/bin:$PATH" FAKE_LAYOUT="$layout" FAKE_CALL_LOG="$log" \
    "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" >/dev/null
  [[ "$(wc -l <"$log" | tr -d ' ')" -gt 250 ]]
  printf '%s\n' "$log"
}

named_log="$(run_layout named)"
if rg -q -- '--as(=| )' "$named_log"; then
  echo 'Named-context layout unexpectedly used impersonation.' >&2
  exit 1
fi
rg -q -- '--context homelab-observer' "$named_log"
rg -q -- '--context homelab-diagnostic' "$named_log"

admin_log="$(run_layout admin)"
if rg -q -- '--context(=| )' "$admin_log"; then
  echo 'Admin fallback unexpectedly selected a named context.' >&2
  exit 1
fi
while IFS= read -r call; do
  rg -q -- '--as=system:serviceaccount:kube-system:homelab-(observer|diagnostic)' <<<"$call"
  rg -q -- '--as-group=system:authenticated' <<<"$call"
  rg -q -- '--as-group=system:serviceaccounts ' <<<"$call"
  rg -q -- '--as-group=system:serviceaccounts:kube-system' <<<"$call"
done <"$admin_log"

if PATH="$fixture/bin:$PATH" FAKE_LAYOUT=partial FAKE_CALL_LOG="$fixture/partial.log" \
  "$verifier" "$fixture/kubeconfig" "$fixture/talosconfig" >"$fixture/partial.out" 2>&1; then
  echo 'Partial scoped context layout unexpectedly passed.' >&2
  exit 1
fi
rg -q 'requires both scoped contexts or neither' "$fixture/partial.out"

echo 'Agent access verifier credential-layout tests passed.'
