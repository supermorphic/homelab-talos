#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-flux-source-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"
export FLUX_TEST_ROOT="$fixture_root"
export PATH="$fixture_root/bin:$PATH"
revision='0123456789abcdef0123456789abcdef01234567'
export FLUX_TEST_REVISION="$revision"
real_just="$(command -v just)"

cat >"$fixture_root/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
*' get deployment '*)
  [[ "${FLUX_TEST_MISSING_CONTROLLER:-false}" != true ]] || exit 1
  echo 1 ;;
*' config view '*) echo 'https://192.168.90.20:6443' ;;
*' get secret flux-system-forgejo '*) cat "$FLUX_TEST_ROOT/secret.json" ;;
*' apply --kustomize kubernetes/flux/clusters/prod/flux-system '*) echo apply >>"$FLUX_TEST_ROOT/calls" ;;
*' get gitrepository '*) cat "$FLUX_TEST_ROOT/source.json" ;;
*' get kustomizations '*) cat "$FLUX_TEST_ROOT/kustomizations.json" ;;
*' get kustomization '*)
  for name in flux-system cluster-apps cilium flux-canary; do
    if [[ " $* " == *" get kustomization $name "* ]]; then
      NAME="$name" yq -o=json '.items[] | select(.metadata.name == strenv(NAME))' "$FLUX_TEST_ROOT/kustomizations.json"
      exit
    fi
  done
  exit 1 ;;
*' get ocirepository '*) echo '{"spec":{"ref":{"tag":"1.19.3"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
*' get helmrelease '*)
  [[ "${FLUX_TEST_MISSING_OWNERSHIP:-false}" != true ]] || exit 1
  echo '{"spec":{"releaseName":"cilium"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
*' wait '*) ;;
*) echo "Unexpected kubectl call: $*" >&2; exit 1 ;;
esac
EOF
cat >"$fixture_root/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
'remote get-url origin') echo https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos.git ;;
'ls-remote --exit-code origin refs/heads/main') printf '%s\trefs/heads/main\n' "$FLUX_TEST_REVISION" ;;
'status --porcelain'|'cat-file -e '*|'diff --quiet '*) ;;
*) echo "Unexpected git call: $*" >&2; exit 1 ;;
esac
EOF
cat >"$fixture_root/bin/flux" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == check || "$1" == reconcile ]]
EOF
cat >"$fixture_root/bin/just" <<'EOF'
#!/usr/bin/env bash
case "$*" in
'kube cilium-postflight'|'kube cilium-status') ;;
'kube flux-preflight') echo preflight >>"$FLUX_TEST_ROOT/calls" ;;
*) exit 1 ;;
esac
EOF
chmod +x "$fixture_root/bin/"*

reset_fixture() {
	cat >"$fixture_root/source.json" <<EOF
{"metadata":{"generation":2},"spec":{"url":"https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos.git","ref":{"branch":"main"},"secretRef":{"name":"flux-system-forgejo"}},"status":{"observedGeneration":2,"conditions":[{"type":"Ready","status":"True","observedGeneration":2}],"artifact":{"revision":"main@sha1:$revision"}}}
EOF
	FLUX_TEST_REVISION="$revision" yq -n -o=json '
    .items = ["flux-system", "cluster-apps", "cilium", "flux-canary", "example-app"] |
    .items[] |= {"metadata": {"name": ., "generation": 2},
      "spec": {"path": "./kubernetes/apps", "sourceRef": {"kind": "GitRepository", "name": "flux-system"}},
      "status": {"observedGeneration": 2, "conditions": [{"type": "Ready", "status": "True", "observedGeneration": 2}], "lastAppliedRevision": "main@sha1:" + strenv(FLUX_TEST_REVISION)}} |
    (.items[] | select(.metadata.name == "flux-system") | .spec.path) = "./kubernetes/flux/clusters/prod"
  ' >"$fixture_root/kustomizations.json"
}

expect_failure() {
	if scripts/verify/flux.sh /unused "$revision" >"$fixture_root/output" 2>&1; then
		echo "Flux verifier incorrectly accepted $1." >&2
		exit 1
	fi
}

reset_fixture
scripts/verify/flux.sh /unused "$revision"
scripts/verify/flux.sh /unused
for mutation in \
	'.spec.url = "ssh://git@ssh.github.com:443/example/repository"' \
	'.spec.secretRef.name = "flux-system"' \
	'.spec.suspend = true' \
	'.spec.ref.commit = "older-commit"' \
	'.status.observedGeneration = 1' \
	'.status.conditions[0].observedGeneration = 1' \
	'.status.artifact.revision = "other@sha1:" + strenv(FLUX_TEST_REVISION)' \
	'.status.artifact.revision = "main@sha1:old"'; do
	reset_fixture
	yq -i "$mutation" "$fixture_root/source.json"
	expect_failure "$mutation"
done
for mutation in \
	'(.items[] | select(.metadata.name == "flux-system") | .spec.path) = "./wrong"' \
	'(.items[] | select(.metadata.name == "flux-system") | .spec.sourceRef.name) = "other-source"' \
	'(.items[] | select(.metadata.name == "example-app") | .status.lastAppliedRevision) = "main@sha1:old"' \
	'(.items[] | select(.metadata.name == "example-app") | .status.observedGeneration) = 1' \
	'(.items[] | select(.metadata.name == "example-app") | .status.conditions[0].status) = "False"' \
	'(.items[] | select(.metadata.name == "cluster-apps") | .spec.suspend) = true'; do
	reset_fixture
	yq -i "$mutation" "$fixture_root/kustomizations.json"
	expect_failure "$mutation"
done
reset_fixture
if scripts/verify/flux.sh /unused not-a-sha >"$fixture_root/output" 2>&1; then
	echo 'Flux verifier accepted an invalid expected revision.' >&2
	exit 1
fi
echo 'Flux source verifier tests passed.'

# Run the actual bootstrap recipe with synthetic credentials and no live tools.
printf '%s\n' '{"data":{"username":"dXNlcg==","password":"Zml4dHVyZQ=="}}' >"$fixture_root/secret.json"
touch "$fixture_root/calls"
if FLUX_BOOTSTRAP_CONFIRM='' "$real_just" bootstrap flux >"$fixture_root/output" 2>&1; then
	echo 'Flux bootstrap accepted a missing execution guard.' >&2
	exit 1
fi
if rg -q '^apply$' "$fixture_root/calls"; then
	echo 'Flux bootstrap applied without its execution guard.' >&2
	exit 1
fi
for mutation in '.data.password = ""' '.data.password = null' '.data.identity = "fixture"'; do
	printf '%s\n' '{"data":{"username":"dXNlcg==","password":"Zml4dHVyZQ=="}}' >"$fixture_root/secret.json"
	yq -i "$mutation" "$fixture_root/secret.json"
	if FLUX_BOOTSTRAP_CONFIRM='bootstrap:flux:prod:forgejo:read-only' "$real_just" bootstrap flux >"$fixture_root/output" 2>&1; then
		echo "Flux bootstrap accepted invalid credentials: $mutation" >&2
		exit 1
	fi
	if rg -q '^apply$' "$fixture_root/calls"; then
		echo 'Flux bootstrap applied invalid credentials.' >&2
		exit 1
	fi
done
printf '%s\n' '{"data":{"username":"dXNlcg==","password":"Zml4dHVyZQ=="}}' >"$fixture_root/secret.json"
: >"$fixture_root/calls"
FLUX_BOOTSTRAP_CONFIRM='bootstrap:flux:prod:forgejo:read-only' "$real_just" bootstrap flux
[[ "$(<"$fixture_root/calls")" == $'preflight\npreflight\napply' ]]
echo 'Flux bootstrap guard tests passed.'

touch "$fixture_root/kubeconfig"
FLUX_TEST_MISSING_CONTROLLER=true "$real_just" --justfile kubernetes/mod.just \
	--set kubeconfig "$fixture_root/kubeconfig" --no-deps flux-preflight
if FLUX_TEST_MISSING_CONTROLLER=true FLUX_TEST_MISSING_OWNERSHIP=true "$real_just" \
	--justfile kubernetes/mod.just --set kubeconfig "$fixture_root/kubeconfig" \
	--no-deps flux-preflight >"$fixture_root/output" 2>&1; then
	echo 'Flux first-adoption preflight accepted unsuspended Cilium.' >&2
	exit 1
fi
echo 'Flux missing-controller recovery preflight tests passed.'
