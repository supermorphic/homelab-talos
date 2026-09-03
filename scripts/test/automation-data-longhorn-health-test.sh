#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/lib/longhorn-verification.sh"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-longhorn-health.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

cat >"$fixture/volumes.json" <<'JSON'
{
  "apiVersion": "v1",
  "kind": "List",
  "items": [
    {
      "apiVersion": "longhorn.io/v1beta2",
      "kind": "Volume",
      "metadata": {"name": "pvc-data"},
      "status": {
        "state": "attached",
        "robustness": "healthy",
        "kubernetesStatus": {
          "namespace": "automation-data",
          "pvcName": "automation-data-postgresql-data",
          "pvName": "pvc-data"
        },
        "conditions": [
          {"type": "Scheduled", "status": "True"},
          {"type": "Restore", "status": "False"}
        ]
      }
    },
    {
      "apiVersion": "longhorn.io/v1beta2",
      "kind": "Volume",
      "metadata": {"name": "pvc-backups"},
      "status": {
        "state": "detached",
        "robustness": "unknown",
        "kubernetesStatus": {
          "namespace": "automation-data",
          "pvcName": "automation-data-postgresql-backups",
          "pvName": "pvc-backups"
        },
        "conditions": [
          {"type": "Scheduled", "status": "True"},
          {"type": "Restore", "status": "False"}
        ]
      }
    }
  ]
}
JSON

longhorn_volume_matches_claim_health \
  automation-data automation-data-postgresql-data pvc-data active \
  "$fixture/volumes.json"
longhorn_volume_matches_claim_health \
  automation-data automation-data-postgresql-backups pvc-backups retained-backup \
  "$fixture/volumes.json"

yq -o=json '
  (.items[] | select(.metadata.name == "pvc-backups") | .status.state) = "attached" |
  (.items[] | select(.metadata.name == "pvc-backups") | .status.robustness) = "healthy"
' "$fixture/volumes.json" >"$fixture/attached-backup.json"
longhorn_volume_matches_claim_health \
  automation-data automation-data-postgresql-backups pvc-backups retained-backup \
  "$fixture/attached-backup.json"

yq -o=json '
  (.items[] | select(.metadata.name == "pvc-data") | .status.state) = "detached" |
  (.items[] | select(.metadata.name == "pvc-data") | .status.robustness) = "unknown"
' "$fixture/volumes.json" >"$fixture/detached-data.json"
if longhorn_volume_matches_claim_health \
  automation-data automation-data-postgresql-data pvc-data active \
  "$fixture/detached-data.json"; then
  echo 'Longhorn health accepted a detached active data volume.' >&2
  exit 1
fi

expect_rejected() {
  local name="$1" expression="$2"
  yq -o=json "$expression" "$fixture/volumes.json" >"$fixture/$name.json"
  if longhorn_volume_matches_claim_health \
    automation-data automation-data-postgresql-backups pvc-backups retained-backup \
    "$fixture/$name.json"; then
    echo "Longhorn health accepted invalid retained-backup fixture: $name" >&2
    exit 1
  fi
}

expect_rejected attached-unknown \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.state) = "attached"'
expect_rejected detached-degraded \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.robustness) = "degraded"'
expect_rejected unscheduled \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.conditions[] | select(.type == "Scheduled") | .status) = "False"'
expect_rejected restoring \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.conditions[] | select(.type == "Restore") | .status) = "True"'
expect_rejected conflicting-scheduling \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.conditions) += [{"type": "Scheduled", "status": "False"}]'
expect_rejected conflicting-restore \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.conditions) += [{"type": "Restore", "status": "True"}]'
expect_rejected wrong-claim \
  '(.items[] | select(.metadata.name == "pvc-backups") | .status.kubernetesStatus.pvcName) = "other-backups"'

echo 'automation-data Longhorn volume health behavior passed.'
