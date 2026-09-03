#!/usr/bin/env bash
set -euo pipefail

node_ip=''
previous=''
for argument in "$@"; do
  if [[ "$previous" == '--nodes' ]]; then
    node_ip="$argument"
    break
  fi
  previous="$argument"
done
case "$node_ip" in
  192.168.90.10) node='nuc1' ;;
  192.168.90.11) node='nuc2' ;;
  192.168.90.12) node='nuc3' ;;
  *) echo "Unexpected test node IP: $node_ip" >&2; exit 2 ;;
esac

case "$1 $2" in
  'get hostname')
    NODE="$node" yq --null-input --output-format json \
      '{"spec":{"hostname":strenv(NODE)}}'
    ;;
  'get securitystate')
    yq --null-input --output-format json \
      '{"spec":{"secureBoot":true,"bootedWithUKI":true}}'
    ;;
  *)
    echo "Unexpected cluster verifier talosctl invocation: $*" >&2
    exit 2
    ;;
esac
