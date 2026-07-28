#!/usr/bin/env bash

# Shared homelab network facts for host-run validation/verification/probe scripts —
# a single source of truth for literals that were otherwise duplicated across many
# scripts. Source with `source scripts/lib/network.sh` (CWD is the repo root for every
# host-run script; matches how scripts/lib/common.sh is sourced).
#
# NOTE: Kubernetes manifests intentionally INLINE these literals — this repo has no Flux
# postBuild var-substitution — so this file centralizes the bash layer only. Keep the
# manifest literals (e.g. the Connector /32 route) and this constant in agreement.

# Pi-hole DNS resolver on the LAN. external-dns publishes records to Pi-hole by hostname
# (`https://pi.hole`), NOT this IP; this address is the dig / split-DNS target used by the
# client-path DNS checks in the verify scripts and probes.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
HOMELAB_DNS_RESOLVER='192.168.90.2'
