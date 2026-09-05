#!/usr/bin/env bash
# Foundation owns internal DNS audience uniqueness across every Kubernetes domain.
set -euo pipefail

public_internal_dns='kubernetes/apps/networking/public-webhook-gateway/app/internal-dns.yaml'
mapfile -t internal_dns_endpoint_sources < <(
  while IFS= read -r candidate; do
    if yq ea -e 'select(
      .kind == "DNSEndpoint" and
      .metadata.annotations."external-dns.k8s.io/audience" == "internal"
    )' "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
    fi
  done < <(rg -l --glob '*.yaml' '^kind:[[:space:]]*DNSEndpoint[[:space:]]*$' kubernetes || true)
)
[[ "${#internal_dns_endpoint_sources[@]}" == '1' && \
  "${internal_dns_endpoint_sources[0]}" == "$public_internal_dns" ]] || {
  echo 'Only the exact public-webhook DNSEndpoint may carry the internal DNS audience.' >&2
  exit 1
}
