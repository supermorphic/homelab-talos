# Grafana Alloy and Loki Centralized Logging

## Intent and topology

Collect Kubernetes container logs, Talos service/kernel logs, and Kubernetes Events for
private Grafana investigation. Prometheus remains the metric/alert evaluator and
Alertmanager remains the delivery owner. There are no LogQL application alerts or public
logging routes.

[Alloy node source](../../kubernetes/apps/monitoring/alloy-logs/),
[Event source](../../kubernetes/apps/monitoring/alloy-events/), and
[Loki source](../../kubernetes/apps/monitoring/loki/) own chart versions, resources,
retention, limits, label allowlists, and pipeline details.

One node-local Alloy collector per production node tails only that node's read-only
host log files. File collection avoids API-tail traffic and reuses the DaemonSet for
Talos sources. Container and Talos matches remain separate. A configured Talos directory
user volume holds read positions on encrypted EPHEMERAL storage; kubelet cannot safely
create an arbitrary child under the read-only `/var/mnt` parent. Pod restarts retain
positions, but node-local state is not backed up. Collectors have neither Talos credentials
nor Kubernetes Secret access.

One separate `Recreate` Event reader watches cluster-wide Events with read-only RBAC.
Running it in every unclustered node collector would duplicate every Event; adding
StatefulSet-based clustering would complicate file collection. Its disposable positions
can replay Events still in the API after restart. That bounded duplication is accepted
because Events are diagnostic context rather than an authoritative record.

## Storage and loss model

One monolithic filesystem-backed Loki instance uses a retained Longhorn claim. A
single-writer StatefulSet prevents overlapping claim writers. Distributed Loki/S3 is
unnecessary at this scale; in-cluster S3 on Longhorn or the NAS would add a service without
an independent failure boundary.

Compactor retention is explicit and its marker/work data persist on the Loki filesystem.
Query lookback must not exceed retention. Filesystem storage does not delete data merely
because free space is low; capacity alerts and measured ingest/growth/compactor progress
are required. Adjust resources, limits, claim size, or retention from measurements rather
than speculative topology growth.

Alloy retries with backoff but has no experimental log write-ahead log. Outages beyond
retry capacity can drop entries. Loki history is disposable telemetry: accepted complete
loss is recovered by recreating storage/service and collecting new logs, not by claiming
backfill. Scheduled application-state backups have a different recovery objective.

## Longhorn maintenance boundary

Loki must not inherit the default recurring snapshot/backup group. Its explicit scheduled
filesystem-trim job reports blocks freed by retention/compaction so replicas can reclaim
them and suppresses automatic assignment of default backup jobs. Avoiding backups also
avoids another retained copy of private log payloads.

Acceptance must inspect the actual Longhorn Volume's labels and job assignment: require
filesystem trim and no daily snapshot, daily backup, or default recurring-job group.
Desired PVC labels alone do not prove the exclusion, and this is a release-blocking live
invariant. Longhorn replication tolerates routine node failure but does not promise
recovery of complete Loki loss.

## Cardinality and privacy

Every source uses an explicit indexed-label allowlist with stable workload/node/source
context. Never index arbitrary Kubernetes metadata, Pod/UID/container IDs, paths,
addresses, or request/user/session/torrent/trace identifiers. Structured metadata and
automatic stream sharding remain disabled to prevent another dynamic label surface.
Raw line fields may be parsed privately at query time.

Collection includes all namespaces unless a pod carries
`observability.supermorphic.com/logs: "disabled"`. This is an emergency privacy/noise
control, not a replacement for normal log-level management. CRI reconstruction and bounded
credential redaction mask recognized headers/key-value forms and drop known temporary-
password messages. The pipeline does not guarantee removal of every credential format.

Raw logs can retain client/source addresses and other sensitive payloads. Loki, Alloy,
and Grafana stay internal. Do not publish production lines/query results in Git, issues,
PRs, or reports. Validation evidence uses synthetic lines, aggregate bounded results,
documentation addresses, and invented identifiers.

## Monitoring and acceptance

The existing Grafana datasource sidecar discovers Loki without another alerting path.
ServiceMonitors expose receiver/collector health; Prometheus covers target loss, retry/drop,
rejected ingestion, retention/compaction failure, and storage pressure. Event warnings
remain investigation context rather than direct pages.

Source/render checks enforce topology, Talos directory input, opt-out, cardinality,
retention, limits, and backup-exclusion inputs. Live acceptance separately requires one
node collector per production node, one Event reader and receiver, healthy Grafana access,
recent entries from all source classes, bounded indexed labels, working retention,
actual Longhorn job exclusion, and healthy targets/rules. A YAML render or healthy
scrape alone does not establish ingestion or maintenance state.

Review after measured growth/capacity or query problems, substantial scale change, or a
new independently justified object-storage dependency. None alone authorizes a broader
retention or public evidence boundary.
