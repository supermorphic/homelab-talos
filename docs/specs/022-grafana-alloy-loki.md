# Grafana Alloy and Loki Centralized Logging

## Purpose

Add centralized logs to the existing Grafana and Prometheus observability platform for
[issue 288](https://github.com/supermorphic/homelab-talos/issues/288). The system collects
Kubernetes container logs, Talos service and kernel logs from all three production NUCs,
and Kubernetes Events. Grafana provides the common investigation interface, Prometheus
continues to own metrics and alert evaluation, and Alertmanager continues to own alert
delivery.

The target flow is:

```text
Kubernetes container files --+
Talos service/kernel files ---+--> alloy-logs DaemonSet --+
                                                          +--> Loki --> Grafana
Kubernetes Events ----------------> alloy-events ---------+
                                         |
Prometheus <--------- Alloy and Loki operational metrics -+
```

## Existing platform context

The cluster has three schedulable Talos NUCs. The existing monitoring stack uses
`kube-prometheus-stack` in the `monitoring` namespace. Prometheus retains metrics for 30
days on a 50 GiB Longhorn claim, Grafana uses a 10 GiB Longhorn claim, and Grafana's
datasource sidecar discovers labeled datasource ConfigMaps. Longhorn supplies replicated
block storage from a dedicated 500 GiB user volume on each node, with two replicas and
hard node anti-affinity by default.

Longhorn's built-in `default` recurring-job group creates daily local snapshots and daily
NAS backups with seven retained runs. Those jobs protect application configuration and
state. Loki data is disposable telemetry and does not need the same recovery objective.

The repository has no active S3-compatible storage service or object-storage consumer.
Adding MinIO on Longhorn would provide an S3 API but would not create an independent
failure boundary. Adding it on the same NAS would retain the NAS failure boundary while
adding another service to operate. This design therefore uses Loki's filesystem storage
on Longhorn and does not introduce S3.

## Goals

- Collect container logs from all Kubernetes namespaces by default.
- Collect Talos service and kernel logs from all three production nodes.
- Collect Kubernetes Events as short-lived diagnostic context.
- Retain every accepted source for 14 days.
- Make logs available through Grafana Explore and a focused overview dashboard.
- Keep labels stable and bounded, and detect discarded logs and storage pressure.
- Reuse Grafana, Prometheus, Alertmanager, Flux, and Longhorn without introducing a
  competing observability or alerting path.
- Keep Loki internal and exclude its data from daily Longhorn snapshots and NAS backups.

## Non-goals

- S3-compatible storage, MinIO, Thanos, Mimir, or another long-term telemetry platform.
- High availability for Loki or durable recovery of retained logs after storage loss.
- Kubernetes Event alerting or application alerts evaluated from LogQL.
- Arbitrary application payload parsing or automatic promotion of discovered metadata.
- Public Loki or Alloy HTTP routes.
- Backfilling logs that predate deployment or recovering all logs after a prolonged Loki
  outage.

## Collection architecture

### Node and container logs

One Alloy Helm release, `alloy-logs`, runs as a DaemonSet with one pod on every production
node. Each pod discovers only pods scheduled to its node and reads their CRI files from
the host `/var/log` tree. File-based collection avoids the extra kubelet CPU and network
traffic caused by tailing every container through the Kubernetes API.

The DaemonSet also reads Talos service and kernel log files exposed in the host `/var/log`
tree. Container and Talos file matches remain separate so their processing rules and
labels cannot be confused. The host log tree is mounted read-only. A dedicated writable
host path on Talos EPHEMERAL storage holds Alloy's local read positions so ordinary pod
restarts do not replay previously consumed files. Position data is local to a node and is
not backed up.

The DaemonSet uses only the host access needed to read those files and write its position
state. It does not receive Talos API credentials, Kubernetes Secrets access, or a public
administration endpoint.

### Kubernetes Events

A second Alloy Helm release, `alloy-events`, runs as a single-replica Deployment. It uses
`loki.source.kubernetes_events` with cluster-scoped read access to Events and watches all
namespaces. It has no access to Secrets or mutation APIs.

The Deployment uses `Recreate` so a normal rollout does not intentionally overlap two
Event readers. Its position directory is disposable. After a restart, it can replay
Events still exposed by the Kubernetes API. The duplication is bounded by Kubernetes
Event retention and is acceptable because Events are investigation context rather than
an authoritative record or alert source.

This separate reader avoids enabling Alloy clustering for the node-log DaemonSet. The
documented Alloy Helm clustering topology requires a StatefulSet, while local host-file
collection is naturally a DaemonSet concern. The extra Alloy pod therefore has a clear,
limited purpose: it prevents every node collector from duplicating the same cluster-wide
Events.

### Delivery

Both Alloy releases write to Loki's internal ClusterIP service in single-tenant mode.
Alloy retries failed batches with backoff. The experimental Alloy log write-ahead log is
not enabled. When Loki remains unavailable beyond the retry window, Alloy can discard
entries and the retained log history can have a gap. Prometheus alerts on retry and drop
counters. This best-effort behavior matches the decision not to back up Loki.

## Loki architecture

Loki runs as one monolithic instance in `monitoring`. This topology is appropriate for
the estimated ingest rate and avoids the operational cost of distributed Loki services.
The service is internal; Grafana and the two Alloy workloads are its expected clients.

Loki uses TSDB schema v13 with a 24-hour index period and filesystem-backed chunk, index,
WAL, and compactor data on one 50 GiB Longhorn `ReadWriteOnce` claim. The workload uses a
StatefulSet, or a `Recreate` Deployment if required by the selected chart topology, so it
never mounts the claim through a rolling two-pod transition.

The Compactor runs as part of the single monolith. Retention is explicitly enabled, uses
the persistent Loki filesystem for its working and marker data, and applies a global
`336h` retention period. Query lookback does not exceed that period. Filesystem storage
does not delete data in response to free-space pressure, so Prometheus alerts provide the
capacity safety boundary.

The Loki chart's Helm test is disabled because it requires the intentionally disabled
Loki Canary. Prometheus instead scrapes the monolith through its ServiceMonitor.

## Retention and capacity

Repository workload count and expected source volume support a planning envelope of
50--100 KiB/s, or approximately 4--8 GiB/day of raw text. With an estimated 5--10x
compression ratio and index/compactor overhead, expected stored growth is 1--2 GiB/day.

| Retention | Estimated stored data | Recommended claim |
| --- | ---: | ---: |
| 7 days | 7--14 GiB | 25 GiB |
| 14 days | 14--28 GiB | 50 GiB |
| 30 days | 30--60 GiB | 100 GiB |

The selected design is 14 days on a 50 GiB claim. Longhorn's two replicas reserve up to
100 GiB of nominal cluster capacity. Warning and critical alerts fire at 70 and 85 percent
claim use. Ingest rate, stored-byte growth, compactor progress, and remaining capacity are
reviewed after the first two weeks of production data. A later size or retention change
uses measured data rather than replacing filesystem storage preemptively.

### Snapshot and backup exclusion

The Loki claim must not fall back to Longhorn's `default` recurring-job group. The
implementation defines a scheduled filesystem-trim recurring job as an intentional
maintenance operation for Loki's high-churn filesystem. Trimming reports blocks freed by
retention and compaction back to Longhorn so replica storage can reclaim them. The Loki
PVC selects this job using Longhorn's PVC recurring-job source labels. Because the volume
then has an explicit recurring job, Longhorn does not automatically assign the default
daily snapshot and backup jobs.

Inspecting the resulting Longhorn Volume labels and recurring-job assignment is a
non-negotiable, release-blocking acceptance test. Checking only the desired PVC manifest
is insufficient. The actual volume must show the filesystem-trim maintenance job and must
not show `daily-snapshot`, `daily-backup`, or the `default` group. The implementation is
not complete until this live-state check passes.

## Resource and ingestion limits

Initial resource envelopes are deliberately small but leave room for bursts:

| Workload | CPU request / limit | Memory request / limit |
| --- | ---: | ---: |
| Loki monolith | 250m / 2 cores | 1 GiB / 3 GiB |
| `alloy-logs`, per node | 100m / 1 core | 128 MiB / 512 MiB |
| `alloy-events` | 25m / 250m | 64 MiB / 256 MiB |

Loki initially allows 2 MiB/s sustained ingestion with a 4 MiB burst, 1 MiB/s per stream,
256 KiB per log line, and 5,000 active streams for the single tenant. These values are
guardrails against event storms, runaway debug logging, and unintended label expansion.
Any rejected entries increment metrics that Prometheus monitors. Limits and resources may
be adjusted after measurement without changing the architecture.

## Labels and cardinality

Every source has an explicit indexed-label allowlist:

| Source | Indexed labels |
| --- | --- |
| Kubernetes containers | `cluster`, `source`, `namespace`, `app`, `container`, `node`, `stream` |
| Talos | `cluster`, `source`, `node`, `service` |
| Kubernetes Events | `cluster`, `source`, `namespace`, `event_type` |

`source` is one of `kubernetes`, `talos`, or `kubernetes_event`. `event_type` is limited
to the bounded Kubernetes Normal and Warning values. The container `app` value prefers
`app.kubernetes.io/name`, then a normalized controller name with ReplicaSet hashes
removed. A missing stable application value becomes `unknown`. Alloy never copies
arbitrary Kubernetes labels.

The following values are not indexed:

- pod names and UIDs;
- container IDs, image digests, and log file paths;
- Event object names, UIDs, reasons, and reporting instances;
- client, source, pod, and host IP addresses; and
- request, user, session, torrent, and trace identifiers.

Loki structured metadata is disabled initially. Fields not in the allowlist remain only
inside the raw line and can be parsed at query time. This is also a configuration-level
guardrail that prevents IP addresses from becoming structured metadata.

## Filtering and sensitive log content

Container collection includes every namespace by default. A pod with
`observability.supermorphic.com/logs: "disabled"` is removed during discovery before its
file is tailed. This annotation is an emergency privacy and noise control, not a routine
replacement for application log-level configuration.

Alloy reconstructs CRI log lines and applies limited credential redaction before delivery.
It masks recognizable authorization headers and common key/value forms such as
`password`, `token`, `api_key`, and `secret`. Known whole messages that disclose temporary
generated passwords are dropped. The pipeline does not attempt general application
parsing and does not claim to detect every possible credential format.

Raw lines may retain source and client IP addresses for 14 days. Those addresses are not
labels or structured metadata. Loki, Alloy, and Grafana remain internal. Operators and
agents must not paste raw logs or query results into Git, pull requests, issues, test
reports, or other public artifacts. Synthetic fixtures used in repository tests use
documentation addresses and invented identifiers.

## Grafana and operational monitoring

A datasource ConfigMap labeled for Grafana's existing sidecar adds Loki without changing
the upgrade-sensitive `kube-prometheus-stack` values. Grafana Explore is the main query
interface. A focused Centralized Logs dashboard shows:

- volume by source, namespace, application, and node;
- recent Kubernetes Warning Events;
- Talos errors grouped by node and service;
- Loki ingestion rejects and Alloy delivery failures; and
- Loki claim use and stored-data growth.

ServiceMonitors expose Alloy and Loki metrics to the existing Prometheus instance.
PrometheusRules cover missing scrape targets, Alloy entries dropped after retries, Loki
discarded entries by rejection reason, Loki request or ingestion failures, stalled
compaction or retention, and the 70/85-percent claim thresholds. Alertmanager remains the
only alert-delivery system.

No Loki ruler or LogQL application alerts are added. In particular, Kubernetes Warning
Events appear in Grafana for investigation but do not directly page the operator.

## Flux ownership and rollout

The monitoring domain gains separate Loki, Alloy logs, and Alloy Events packages that
follow existing Flux application structure. Loki depends on Longhorn and the existing
monitoring foundation. Both Alloy packages depend on Loki so first deployment normally
establishes the receiver before collectors start. Runtime loss of Loki does not block
Alloy reconciliation; Alloy retries and reports delivery failures.

The implementation pins compatible Loki and Alloy chart versions through the repository's
existing HelmRepository and HelmRelease patterns. No chart upgrade is bundled unless it
is required for this design and validated as part of the same change.

## Validation and acceptance

Cluster-independent validation must include the canonical `mise exec -- just ci` gate.
Focused tests or rendered-manifest assertions must verify the label allowlist, pod
opt-out, retention, ingestion limits, resource envelopes, internal-only services,
single-reader Event topology, and Longhorn backup exclusion inputs.

Scoped live acceptance verifies:

1. One `alloy-logs` pod runs on each production NUC, with one `alloy-events` pod and one
   Loki pod.
2. Grafana reports a healthy Loki datasource.
3. Queries return recent container, Talos service, Talos kernel, and Kubernetes Event
   entries.
4. Indexed labels match the allowlist and omit IPs and dynamic identifiers.
5. Loki reports 336-hour retention and successful compaction.
6. As a non-negotiable release gate, the actual Loki Longhorn Volume labels show the
   filesystem-trim maintenance job and no daily snapshot, daily backup, or `default`
   recurring-job assignment. Desired PVC labels alone do not satisfy this check.
7. Prometheus scrapes Alloy and Loki, and the new alert rules evaluate without errors.

Live evidence must use bounded aggregate results or synthetic lines. It must not publish
raw production log content or unique infrastructure identifiers.

## Rejected alternatives

### One Alloy DaemonSet for every source

Running the Event component in every unclustered DaemonSet pod duplicates cluster-wide
Events. Enabling clustering conflicts with the documented StatefulSet Helm topology and
adds coordination that local file collection does not need. A dedicated one-replica Event
reader is clearer.

### Centralized API-based container collection

A central Alloy StatefulSet could tail pod logs through the Kubernetes API and distribute
work with clustering. It cannot collect node logs directly, increases kubelet CPU and
network traffic, and still requires a second Talos transport path. It adds complexity
without a useful benefit at this scale.

### Talos network log forwarding

Talos can send service logs to a network destination and kernel logs through separate
configuration. File collection reuses the required per-node DaemonSet, avoids another
network listener, and keeps both Talos sources on one local path.

### S3-compatible storage

S3 is Loki's preferred scalable production backend, but the current cluster has no S3
service and the estimated log volume fits a monolithic filesystem deployment. In-cluster
S3 on Longhorn would remain dependent on Longhorn, while S3 on the NAS would remain
dependent on the same NAS. Neither provides enough new resilience to justify another
stateful platform service.

### Loki snapshots and NAS backups

Backups would consume local and NAS capacity for reproducible diagnostic data while
retaining sensitive log payloads in a second location. Two Longhorn replicas provide
routine node-failure tolerance. Complete Loki loss is accepted and recovery consists of
recreating the service and collecting new logs.

## Review triggers

Revisit the design when sustained stored growth exceeds 2 GiB/day, the 50 GiB claim
regularly crosses 70 percent, query performance becomes unacceptable, the cluster adds
substantially more nodes, or another approved service creates a genuine S3 requirement.
Those conditions may justify a larger claim, adjusted retention, a distributed Loki
topology, or shared object storage. They do not require those changes in advance.

Before merge, reconcile this specification with the implemented chart versions,
configuration fields, measured validation results, and any design changes discovered
during implementation.

## External references

- [Talos logging](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/logging-and-telemetry/logging)
- [Collect Kubernetes logs with Alloy](https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/)
- [Alloy Kubernetes Events source](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.kubernetes_events/)
- [Alloy clustering](https://grafana.com/docs/alloy/latest/configure/clustering/)
- [Alloy Loki writer](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.write/)
- [Loki deployment modes](https://grafana.com/docs/loki/latest/get-started/deployment-modes/)
- [Loki retention](https://grafana.com/docs/loki/latest/operations/storage/retention/)
- [Longhorn recurring snapshots and backups](https://longhorn.io/docs/1.12.0/snapshots-and-backups/scheduling-backups-and-snapshots/)

## Pull request linkage

Every pull request produced by this initiative links
[GitHub issue 288](https://github.com/supermorphic/homelab-talos/issues/288) in its
description. Partial pull requests use `Related to #288`. Only the pull request that
finishes the accepted issue scope uses `Closes #288`.
