#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/encode-benchmark.sh"
alert_manifest="$repo_root/kubernetes/apps/media/alerts/app/encode-benchmark.yaml"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/encode-benchmark-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

alert_namespace="$(yq -r '.metadata.namespace' "$alert_manifest")"
[[ "$alert_namespace" == 'monitoring' ]] || {
	echo "Unexpected encode-benchmark alert namespace: $alert_namespace" >&2
	exit 1
}

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case " $* " in
	*' config view --minify '*)
		printf 'https://192.168.90.20:6443'
		;;
	*' --namespace flux-system get kustomization encode-benchmark '*)
		printf '%s\n' '{"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
		;;
	*' get priorityclass encode-benchmark-background '*)
		printf '%s\n' '{"metadata":{"name":"encode-benchmark-background"},"value":-10}'
		;;
	*' --namespace media get configmaps '*)
		printf '%s\n' '{"items":[{"metadata":{"name":"encode-benchmark-samples"}},{"metadata":{"name":"encode-benchmark-scripts-aaaaaaaaaa"}}]}'
		;;
	*' --namespace monitoring get prometheusrule encode-benchmark '*)
		printf '%s\n' '{"metadata":{"name":"encode-benchmark"}}'
		;;
	*' get prometheusrule encode-benchmark '*)
		echo "PrometheusRule queried in the wrong namespace: $*" >&2
		exit 1
		;;
	*' --namespace media get deployment,statefulset,daemonset,cronjob '*)
		printf '%s\n' '{"items":[]}'
		;;
	*' --namespace media get pods --selector app.kubernetes.io/name=plex '*)
		printf '%s\n' '{"items":[{"spec":{"nodeName":"node-a"},"status":{"phase":"Running"}}]}'
		;;
	*' --namespace media get pods --selector app.kubernetes.io/name=encode-benchmark '*)
		printf '%s\n' '{"items":[]}'
		;;
	*)
		echo "Unexpected kubectl request: $*" >&2
		exit 64
		;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

PATH="$fixture/bin:$PATH" "$verifier" "$fixture/kubeconfig"

echo 'encode-benchmark verifier uses the alert manifest namespace.'
