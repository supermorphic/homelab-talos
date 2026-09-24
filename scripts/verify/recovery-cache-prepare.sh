#!/usr/bin/env bash
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 1 && "$1" == /* ]] || {
  echo 'Usage: recovery-cache-prepare.sh /absolute/cache/directory' >&2
  exit 2
}
destination="$1"
[[ -z "$(git status --porcelain=v1 --untracked-files=all)" ]] || {
  echo 'Recovery cache preparation refused: selected source checkout is dirty.' >&2
  exit 1
}
[[ ! -e "$destination" ]] || {
  echo "Refusing to overwrite existing recovery chart cache: $destination" >&2
  exit 1
}
parent="$(dirname "$destination")"
mkdir -p "$parent"
temp_dir="$(mktemp -d "$parent/.recovery-helm.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

revision="$(git rev-parse HEAD)"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]]
cilium_version="$(yq -r '.spec.ref.tag' kubernetes/apps/kube-system/cilium/app/ocirepository.yaml)"
cert_manager_version="$(yq -r '.spec.ref.tag' kubernetes/apps/security/cert-manager/app/ocirepository.yaml)"
metallb_version="$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/metallb/app/helmrelease.yaml)"
envoy_gateway_version="$(yq -r '.spec.ref.tag' kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml)"
external_dns_version="$(yq -r '.spec.chart.spec.version' kubernetes/apps/networking/external-dns/app/helmrelease.yaml)"

pull_chart() {
  local logical="$1"
  shift
  local work="$temp_dir/pull-$logical" archive
  mkdir "$work"
  helm pull "$@" --destination "$work"
  mapfile -t archives < <(find "$work" -maxdepth 1 -type f -name '*.tgz' -print)
  [[ "${#archives[@]}" -eq 1 ]] || {
    echo "Preparation did not produce one archive for $logical." >&2
    return 1
  }
  archive="${archives[0]}"
  mv "$archive" "$temp_dir/$logical.tgz"
  rmdir "$work"
}

pull_chart cilium oci://quay.io/cilium/charts/cilium --version "$cilium_version"
pull_chart cert-manager oci://quay.io/jetstack/charts/cert-manager --version "$cert_manager_version"
pull_chart metallb metallb --repo https://metallb.github.io/metallb --version "$metallb_version"
pull_chart envoy-gateway oci://docker.io/envoyproxy/gateway-helm --version "$envoy_gateway_version"
pull_chart external-dns external-dns --repo https://kubernetes-sigs.github.io/external-dns --version "$external_dns_version"

REVISION="$revision" CACHE_DIR="$temp_dir" \
CILIUM_VERSION="$cilium_version" CERT_MANAGER_VERSION="$cert_manager_version" \
METALLB_VERSION="$metallb_version" ENVOY_GATEWAY_VERSION="$envoy_gateway_version" \
EXTERNAL_DNS_VERSION="$external_dns_version" python - <<'PY'
import hashlib
import json
import os
from pathlib import Path

cache = Path(os.environ["CACHE_DIR"])
expected = {
    "cilium": ("cilium", os.environ["CILIUM_VERSION"]),
    "cert-manager": ("cert-manager", os.environ["CERT_MANAGER_VERSION"]),
    "metallb": ("metallb", os.environ["METALLB_VERSION"]),
    "envoy-gateway": ("gateway-helm", os.environ["ENVOY_GATEWAY_VERSION"]),
    "external-dns": ("external-dns", os.environ["EXTERNAL_DNS_VERSION"]),
}
charts = {}
for logical, (name, version) in expected.items():
    archive = cache / f"{logical}.tgz"
    charts[logical] = {
        "file": archive.name,
        "chartName": name,
        "version": version,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
    }
(cache / "manifest.json").write_text(
    json.dumps(
        {
            "schemaVersion": 1,
            "sourceRevision": os.environ["REVISION"],
            "charts": charts,
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
PY

mv "$temp_dir" "$destination"
trap - EXIT
echo "Prepared exact recovery chart cache at $destination for $revision."
