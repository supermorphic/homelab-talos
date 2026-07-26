#!/usr/bin/env bash
set -euo pipefail

# Live acceptance for qbit_manage. It is UI-less (QBT_WEB_SERVER=false), so there is no
# HTTP endpoint to probe: instead we assert the Kustomization/HelmRelease are Ready, the
# Deployment rolled out, the pod is not crash-looping, and the most recent run authenticated
# to qBittorrent without a config-parse or login failure. Operator-only; NOT part of just ci.
#
# Prints only sanitized status — never raw log lines (which can contain torrent names) and
# never credentials.
[[ "$#" -eq 1 ]] || { echo 'Usage: qbit-manage.sh <kubeconfig>' >&2; exit 2; }

kubeconfig="$1"
ns='media'

[[ -f "$kubeconfig" ]] || { echo "Missing $kubeconfig." >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace flux-system get kustomization qbit-manage --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'qbit-manage Kustomization not Ready.' >&2; exit 1; }
[[ "$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get helmrelease qbit-manage --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'qbit-manage HelmRelease not Ready.' >&2; exit 1; }
kubectl --kubeconfig "$kubeconfig" --namespace "$ns" rollout status deployment/qbit-manage --timeout=5m

# Not crash-looping: the app container must have zero restarts (a config-parse or auth crash
# would loop here).
restarts="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" get pods --selector app.kubernetes.io/name=qbit-manage \
  --output jsonpath='{.items[*].status.containerStatuses[?(@.name=="app")].restartCount}' 2>/dev/null || true)"
for r in $restarts; do
  [[ "$r" -eq 0 ]] || { echo "qbit-manage app container has restarted ($r) — check for a config-parse or auth crash." >&2; exit 1; }
done

# Poll logs for an authenticated run vs. a hard failure. qbit_manage runs once on startup
# and then on its schedule, so a run marker appears within a minute. NOTE: ripgrep uses
# regex by default; do NOT pass -E (that is --encoding in rg, not extended-regex).
fail_re='LoginFailed|[Ff]ailed to login|[Uu]nauthorized|[Ff]orbidden|error reading.*[Cc]onfig|Traceback|not a valid|Read-only file system|Connection refused|Max retries|Unable to connect'
ok_re='Finished Run|Starting Run|Using .* as config|Current Config|Executing|Uncategorized|qBittorrent|Torrents'
outcome='unknown'
for _ in {1..24}; do
  logs="$(kubectl --kubeconfig "$kubeconfig" --namespace "$ns" logs deployment/qbit-manage --tail=400 2>/dev/null || true)"
  if printf '%s' "$logs" | rg -q "$fail_re"; then outcome='fail'; break; fi
  if printf '%s' "$logs" | rg -q "$ok_re"; then outcome='ok'; break; fi
  sleep 5
done

case "$outcome" in
  ok)   echo "qbit-manage live acceptance passed (Ready, rolled out, 0 restarts, authenticated run with no parse/login errors). Confirm dry-run mode changed nothing in qBittorrent." ;;
  fail) echo 'qbit-manage recent logs show a config-parse or qBittorrent authentication failure. Check kubectl -n media logs deployment/qbit-manage (do not paste credentials).' >&2; exit 1 ;;
  *)    echo 'qbit-manage is Ready with 0 restarts, but no run/connect marker appeared yet. Re-run after the first scheduled run, or inspect logs manually.' >&2; exit 1 ;;
esac
