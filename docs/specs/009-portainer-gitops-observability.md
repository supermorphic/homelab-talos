# Portainer GitOps Observability

## Purpose

Provide an internal operational view of the Talos Kubernetes cluster without creating a
second desired-state or deployment authority. Portainer may inventory resources, show
events and metrics, and read pod logs. Git remains the source of truth and Flux remains
the reconciler.

Portainer complements the existing observability surfaces: Prometheus and Grafana own
metrics and alert-oriented analysis, Gatus owns synthetic availability, and Homepage
owns lightweight navigation and status, while Portainer supplies interactive Kubernetes
inventory, events, metrics, and logs without becoming another deployment interface.

## Workload, route, and storage

Portainer CE runs in the `portainer` namespace using the pinned
`portainer/portainer-ce:2.39.5` image and Helm chart `239.5.0`. It is a single
`Recreate` Deployment with a retained 5 Gi Longhorn `ReadWriteOnce` claim for its
database.

The application is available only through the internal Gateway at
`portainer.lab.supermorphic.com`. A Helm post-renderer removes the chart's Edge port
`8000` and HTTPS Service port `9443`; the Gateway reaches only the ClusterIP Service on
port `9000`. Node probes still reach the pod's HTTPS port directly. There is no public
route, NodePort, Edge tunnel, or Docker Agent.

## Kubernetes authority boundary

The chart's `localMgmt` option remains false so it does not create or bind its
cluster-administrator identity. Because chart `239.5.0` also omits
`serviceAccountName` in this mode, the Helm post-renderer attaches the repository-owned
`portainer-readonly` ServiceAccount to the Deployment.

The corresponding ClusterRole permits `get`, `list`, and `watch` over the workload,
node, event, configuration, storage, metrics, Gateway API, Flux, RBAC metadata, and
selected Longhorn inventory needed by the UI. It grants `get` on pod logs. It does not
grant Secret reads, wildcard permissions, mutation, bind, escalate, impersonate, pod
execution, attach, or port forwarding.

Kubernetes authorization is the enforcement authority. A control displayed by the
Portainer UI does not imply that the ServiceAccount can perform the action. Negative
authorization checks must continue to return `Forbidden` for mutation and sensitive
reads.

`localMgmt: false` has a non-obvious chart boundary: it suppresses the chart's
cluster-administrator resources, but it does not disable discovery of the local
Kubernetes environment. The post-rendered ServiceAccount therefore lets Portainer
register that environment automatically while the injected identity keeps it
read-oriented. Initial acceptance required the local environment to appear without an
Agent, imported kubeconfig, or a second cluster-management identity.

The Cilium policy limits application ingress to internal Envoy on port `9000` and node
probes on `9443`. Egress is limited to the Kubernetes API and CoreDNS. This prevents the
server from becoming a general-purpose network pivot even though it has cluster-wide
read visibility.

## Credential and persistence boundary

The bootstrap administrator credential is stored in a SOPS-encrypted Secret. It is used
only when Portainer creates the first administrator in a new database. Changing that
Secret does not rotate an administrator already stored on the retained claim, so live
password rotation and the disaster-recovery bootstrap value must be kept aligned.

The retained database preserves the local environment and UI state. Its Longhorn volume
uses the platform snapshot and backup policy. Loss of Portainer or its database does not
change or remove any Flux-managed workload.

Pod recreation was accepted only after the replacement retained the same claim and
recovered the local environment and UI state. That test proves ordinary persistence,
not high availability or the usability of a later backup restore. Portainer remains one
writer, and loss of its database loses Portainer-owned users, tokens, and UI state while
leaving the cluster desired state intact.

## Observability and validation

Homepage discovers the internal route and uses a separate SOPS-encrypted API key for the
Kubernetes inventory widget. Separating that token gives it an independent lifecycle;
it does not make the token least-privilege. A Portainer access token carries the
authority of the user that created it, and the current CE design has not proved a
narrower compatible role for all required widget calls. Gatus checks the complete
internal HTTPS path. Prometheus
rules cover sustained route failure, missing Gatus telemetry, and an absent or unbound
Portainer claim.

Offline checks render the chart with its post-renderers and validate the single Service
port, internal route, retained RWO storage, `Recreate` strategy, explicit ServiceAccount,
RBAC allowlist and denials, network policy, encrypted Secret metadata, and monitoring
rules. Live verification uses Kubernetes authorization as an independent oracle and
checks both allowed reads and denied Secret, mutation, execution, attach, and
port-forward actions.

## Deferred and rejected alternatives

- Enabling chart local management was rejected because its generated cluster-admin
  binding would make Portainer a competing deployment authority.
- Portainer stacks and Helm deployment through the UI are outside the design for the
  same reason.
- Standard Agents on LAN Docker hosts are deferred. Their Docker socket access carries
  host-level authority, and Portainer CE does not provide a genuinely read-only Docker
  role. Any later integration requires separate approval and design, a disposable Agent
  measurement from every scheduler location before fixing the egress allowlist, shared
  agent authentication, wrong-secret rejection, bounded network paths, and continued
  Ansible or Compose ownership of desired state.
- Database encryption is not part of the implemented design. Adding it requires a
  separate key lifecycle and recovery design rather than an unreviewed chart toggle.

Material chart upgrades require renewed evidence that `localMgmt: false`, the
post-rendered ServiceAccount, Service-port pruning, and trusted-origin format still have
the same effect. A chart version change is not allowed to silently restore cluster-admin
or another listener.

## Consequences

Operators gain one convenient inventory and diagnostic UI, but Portainer cannot make a
persistent cluster change with its Kubernetes identity. The price of the strong boundary
is that some displayed controls fail and Docker-host management is unavailable. The
single retained database simplifies recovery but makes Portainer itself single-active.

Current credential, acceptance, backup, and recovery procedure belongs in
`docs/guides/portainer-operations.md`.
