#!/usr/bin/env bash

# Shared homelab network facts for host-run validation/verification/probe scripts —
# a single source of truth for literals that were otherwise duplicated across many
# scripts. Source with `source scripts/lib/network.sh` (CWD is the repo root for every
# host-run script; matches how scripts/lib/common.sh is sourced).
#
# NOTE: Kubernetes manifests and chainsaw test YAML intentionally INLINE these literals —
# this repo has no Flux postBuild var-substitution, and YAML cannot source a bash lib — so
# this file centralizes the bash layer only. The *-validate scripts assert the manifest
# literals against these constants, so drift fails `just ci`.

# Pi-hole DNS resolver on the LAN. external-dns publishes records to Pi-hole by hostname
# (`https://pi.hole`), NOT this IP; this address is the dig / split-DNS target used by the
# client-path DNS checks in the verify scripts and probes.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
HOMELAB_DNS_RESOLVER='192.168.90.2'

# Envoy internal Gateway VIP: the single MetalLB address (pool `internal`, pinned via the
# `metallb.io/loadBalancerIPs` annotation on the Envoy Service) that every
# *.lab.supermorphic.com A record points at. Used as the curl --resolve target and the
# HTTPRoute/DNS acceptance address in the verify scripts, and as the second Connector /32
# route. The MetalLB pool RANGE (192.168.90.30-192.168.90.39) is a separate fact, asserted
# inline by the foundation validate/verify scripts.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
HOMELAB_GATEWAY_VIP='192.168.90.30'

# Dedicated public Envoy Gateway VIP. This remains a private LAN address and is the
# sole target of the operator-managed WAN TCP 443 DNAT.
# shellcheck disable=SC2034
HOMELAB_PUBLIC_GATEWAY_VIP='192.168.90.39'
