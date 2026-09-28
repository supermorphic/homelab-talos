# OpenBao credential broker

This package deploys an OpenBao credential broker with three Raft voters. All six Flux
units reconcile through Git. The guarded bootstrap workflow prepares the namespace
Certificate and server after the operator supplies the encrypted `openbao-seal` Secret
and independent recovery destination. Attended acceptance precedes Git activation
of the private route and monitoring.
The expected Secret key is `key`, containing exactly 32 random bytes. No Secret value is
stored in this package.

The official [OpenBao chart](https://github.com/openbao/openbao-helm) is pinned to 0.29.6
from `https://openbao.github.io/openbao-helm`; the equivalent official OCI chart digest
was verified as `sha256:98c8fc901e2579ac6da9a805537fcd7a19525ef8e563ae8737dc16fc8f641e3e`.
The server image is `quay.io/openbao/openbao:2.7.0@sha256:71156a1c6623a5fa3f5e61b0c6a8ead0faf0df29a778339188443551995d1315`,
verified against the registry's OCI index digest. The chart's default server version is
2.6.3, so this package sets 2.7.0 explicitly.

Run `mise exec -- just kube openbao-validate` for offline source and rendered-chart checks.
`validation.openbao` runs in both complete and core CI. The catalog registers
`verification.openbao` with observer access and enrolls it in verification
campaigns with final activation. It fails if any of this package's six Flux
Kustomizations is suspended or the service is staged. Source validation requires
the encrypted seal artifact and enrolled Gatus endpoint. The human-owned
`test.openbao-issuance`, `test.openbao-ha`, and `test.openbao-restore-drill` suites
remain standalone for intentional retained runs. No live result is claimed here.
The reviewed OpenBao mounts, auth roles, policies, and Kubernetes issuance role live in
`config/desired.json` and `config/policies/`. The bootstrap and configuration-apply
workflows read them from clean published and deployed source. They are not mounted into the server or reconciled
by a privileged controller. Drift comparison covers readable live API fields against the
same source inventory; an operator password is intentionally outside that comparison.
The verifier uses `homelab-observer` for Kubernetes state and reads sanitized reader
observations through Prometheus. A single separate `openbao-config-reader` Deployment
uses its own projected audience-bound JWT and read-only OpenBao policy. It has no
Kubernetes API grants, server filesystem, seal, or issuer-token access. Hashed ConfigMaps
mount the shared comparison implementation and desired configuration; changed inputs
replace the reader. Evidence includes actual collection time and a digest of desired,
policy, and reader bytes. The observer independently checks clean/deployed revisions,
rejects incomplete or duplicate evidence, and requires a scrape within two minutes and
collection within five minutes. Failures alert without affecting issuance. Repairs use
the attended, source-bound `openbao-config-apply` workflow.
The chart's default readiness probe requires an initialized, unsealed server. The release
only skips the *initial install wait*; upgrades keep their normal readiness handling.
The native disruption budget protects a two-voter quorum, and StatefulSet claim retention
preserves data after scale-down or deletion. An `OnDelete` upgrade needs an attended
standby-first procedure.

The network policy permits Kubernetes API egress only to the `kube-apiserver` entity
on TCP 6443, the backend port after Cilium translates the Service's TCP 443 address.
Guarded preflight checks the live policy against source and the API EndpointSlices.
The network policy does not grant node-wide API ingress. Guarded bootstrap uses a
loopback-only port-forward to one named Pod; Kubernetes RBAC and the temporary tunnel
bound that access. Cilium's default local-host handling is expected to carry the
kubelet-to-Pod segment. The guarded bootstrap must verify this path before initialization;
no live tunnel behavior is claimed by this staged package.

The application backup CronJob runs at 01:00 UTC, before Longhorn's 02:00 snapshot and
03:00 off-cluster backup jobs. It uses a projected JWT with the dedicated OpenBao
audience and a snapshot-read-only OpenBao role. Its ServiceAccount has no Kubernetes
API permissions. The retained Longhorn claim holds seven validated Raft archive and
sanitized metadata pairs, with a `latest` pointer updated after each complete pair.
The claim selects Longhorn's `default` recurring-job group. Longhorn is configured
to run recurring jobs while selected volumes are detached, so the 02:00 and 03:00
jobs can process this claim after the snapshot Pod exits. That Longhorn setting
also affects other selected detached volumes.
The Python 3.13.14 slim runtime image is pinned to registry index digest
`sha256:9662417aace5ae7b8e2609cce472b72a8958e134ba372808abe9cc1a0c0125e6`.
The archive check follows [OpenBao 2.7.0's snapshot format](https://github.com/openbao/openbao/blob/v2.7.0/internal/physical/raft/snapshot/archive.go).
No seal or recovery material is mounted in the backup job or stored on its claim.

The server HCL declares the hashed stdout audit device. Configuration apply verifies
it and never enables audit devices through the API. Existing staged servers load
reviewed configuration corrections through the attended `bootstrap openbao restart-staged`
command; the StatefulSet retains its `OnDelete` strategy.

One ServiceMonitor scrapes OpenBao's HTTPS monitoring listener; a second selects
Longhorn's manager metrics Service for the backup and capacity alerts. The alerts use
[OpenBao's documented metrics](https://openbao.org/docs/internals/telemetry/metrics/)
and [Longhorn's last successful backup metric](https://longhorn.io/docs/1.12.0/monitoring/metrics/).
The local CronJob success and off-cluster Longhorn transfer have separate freshness
alerts. Homepage discovers the active private route. Gatus checks the private health
endpoint; its expected configuration is retained in
`kubernetes/apps/monitoring/gatus/app/openbao-activation.values.yaml`.

See the [operator operations guide](../../../../docs/guides/openbao-operations.md) for
seal creation, separate prepare/initialize confirmations, encrypted recovery retention,
and configuration repair. All live bootstrap steps remain operator-run.
