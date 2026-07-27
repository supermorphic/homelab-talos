#!/usr/bin/env bash
# Safe dispatcher for read-only network/API probes. Targets are explicitly allowlisted
# here (name -> script), mirroring run-chainsaw.sh: the public target name is the API,
# never the filesystem layout, so no arbitrary path can be forwarded. Operator-run and
# cluster-dependent; never part of `just ci`.
set -euo pipefail

source scripts/lib/common.sh
require_bash

[[ "$#" -eq 1 ]] || {
  echo 'Usage: run-probe.sh <registered-target>' >&2
  exit 2
}

target="$1"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
kubeconfig='.kube/config'

case "$target" in
  qbittorrent)
    suite_id='probe.qbittorrent'
    probe='tests/probes/qbittorrent/probe.sh'
    ;;
  vpn-leak)
    suite_id='probe.vpn-leak'
    probe='tests/probes/vpn/leak-sentinel.sh'
    ;;
  dns-isolation)
    suite_id='probe.dns-isolation'
    probe='tests/probes/dns/isolation.sh'
    ;;
  *)
    echo "Unknown probe target: $target" >&2
    exit 2
    ;;
esac

[[ -f "$kubeconfig" ]] || {
  echo "Missing $kubeconfig; run mise exec -- just talos kubeconfig first." >&2
  exit 1
}

exec scripts/test/run-catalog-suite.sh "$suite_id" -- "$probe" "$kubeconfig"
