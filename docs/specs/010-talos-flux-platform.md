# Talos and Flux Platform

## Purpose

Define the rebuildable architecture for the three-node Talos Linux and Flux GitOps
Kubernetes platform. The design joins machine configuration and cluster desired state in
one repository so changes that cross the operating-system and Kubernetes boundary remain
reviewable together.

This preserves the original architecture and validated outcomes. Current policy, pinned
source, and command help define execution; independent recovery prerequisites and ordering
are retained below.

## Greenfield rebuild

The replacement system drives were introduced before the cluster held workloads or
durable application data. Preserving the earlier Talos identity and migrating its etcd
state would have added recovery risk without preserving useful state. The platform was
therefore rebuilt with a fresh Talos identity and a new source-controlled configuration.
The previous installation was useful as hardware, firmware, Secure Boot, and rollback
evidence, but not as a configuration source.

This choice established a reproducible source of truth and avoided carrying forward
legacy controllers, credentials, generated machine files, or unverified ciphertext.

## Architectural choices and rejected alternatives

The platform favors one owner per responsibility and keeps recovery possible from
reviewed source:

- Proven HomeOps patterns were adopted selectively while local requirements and
  ownership remained explicit. Adopting a cluster template wholesale would also import
  its layout, providers, bootstrap assumptions, naming, and release cadence, then make
  upstream divergence a permanent maintenance concern. Pure DIY would repeat solved
  work in rendering, dependency ordering, secret delivery, and package layout. Copying
  legacy deployment artifacts would preserve obsolete controllers, generated output,
  ciphertext, and implicit discovery rather than the requirements they once served.
  The chosen approach preserves useful intent and reauthors it in current Talos and Flux
  source; templates and legacy repositories remain pattern libraries, not generators or
  deployment inputs.
- One monorepo was chosen over separate machine and application repositories because a
  bootstrap, networking, or storage change often crosses the Talos and Kubernetes
  boundary and must be reviewed as one compatibility decision.
- Talhelper is the only machine-config renderer. Hand-maintained generated Talos files
  and mixed rendering paths were rejected because they obscure secret-bearing output
  and make node configurations diverge.
- Three uniform, schedulable control-plane machines were chosen over a split
  control-plane/worker topology. The hardware can perform both roles, three etcd voters
  preserve quorum, and a second node class would add operational variation without an
  availability gain at this scale.
- Cilium was chosen over the bundled CNI because kube-proxy replacement, policy, and
  Hubble were required as one coherent network layer. A second CNI is unsupported.
- MetalLB L2 owns service address advertisement. Cilium L2 and BGP were rejected for the
  initial platform because they would add another ownership path without a demonstrated
  benefit.
- Envoy Gateway owns Gateway API. A parallel ingress controller was rejected because it
  would duplicate routing, certificate, and exposure policy.
- Flux is the sole Kubernetes reconciler. Argo CD or dual reconciliation was rejected
  because two controllers cannot safely own the same desired state.
- SOPS with an operator-held age identity was chosen over plaintext secrets, replicated
  Secret objects, and additional in-cluster secret controllers. It keeps encrypted
  desired state reviewable without introducing another authority system before there is
  a demonstrated rotation or multi-cluster need.
- Longhorn owns replicated application state while SMB owns shared bulk data. Ceph was
  too complex for three small nodes, local-only storage did not meet rescheduling goals,
  and placing all state on the NAS would make ordinary application availability depend
  on one external system.
- Manual, observable upgrades were retained until upgrade and rollback behavior was
  understood. Lifecycle automation was not accepted as a substitute for that evidence.

## Machine and control-plane design

The cluster uses three uniform `amd64` Talos control-plane nodes. All three are
schedulable, participate in the odd-member etcd quorum, and may host workloads and
advertise LoadBalancer services. The machine specification requires metal mode, UEFI
Secure Boot, TPM support, and the extensions needed for Intel firmware and graphics,
iSCSI, and Longhorn filesystem tooling.

Talos disables its bundled CNI and kube-proxy because Cilium owns both functions.
KubePrism supplies the local Kubernetes API path used by Cilium. The machine patch also
removes the control-plane load-balancer exclusion label so MetalLB can advertise from
every node; this must be a Talos machine-config decision because Talos would restore the
label after an ad hoc Kubernetes edit.

Talos `STATE` and `EPHEMERAL` volumes use LUKS2 encryption with TPM-bound keys tied to
Secure Boot state. The dedicated Longhorn user volume is XFS and remains outside that
TPM encryption boundary so storage recovery does not depend on the original node TPM.
SOPS protects secret values committed to Git and their declarative delivery into
Kubernetes Secrets. It does not encrypt application databases or configuration written
to a PVC. Data on the Longhorn volume follows each application's own storage controls
and is not blanket-encrypted by SOPS or the Talos TPM boundary.

## Source, identity, and generation ownership

[`talos/talconfig.yaml`](../../talos/talconfig.yaml) owns cluster topology, platform
versions, node roles, the machine schematic, and volume policy. Reviewed fragments under
`talos/patches/` own machine changes. The fresh Talos identity is committed only as the
fully encrypted `talos/talsecret.sops.yaml` artifact.

Talhelper renders per-node machine configuration into ignored `clusterconfig/`. These
files contain credentials and are disposable generated output, never source. Agents edit
only the Talhelper inputs and use `mise exec -- just talos source-validate`; generation,
application, and other work requiring the operator-held age key or administrative Talos
credentials remain operator-run.

Kubernetes desired state lives under [`kubernetes/`](../../kubernetes/). Every component
has an explicit Flux Kustomization entrypoint, owns its chart or native manifests and
configuration locally, and is selected by a parent Kustomization. Rendered Helm output
is validation material and is not committed.

## Cilium bootstrap and adoption

Cilium is the only Kubernetes component installed before Flux because nodes cannot
become Ready and Flux cannot run without a CNI. The bootstrap Helm release and the Flux
HelmRelease consume the same tracked values file. Flux first publishes the Cilium package
with pruning disabled and then adopts the existing release through a guarded ownership
transfer. This prevents two controllers from owning different Cilium configurations and
avoids an unnecessary networking rollout during adoption.

The suspension and prune protection were stronger than an ordinary Helm rollout because
Cilium was the cluster's only CNI. A mistaken ownership reconciliation could remove the
network that Flux itself needed to recover, so the transfer had to prove non-disruptive
adoption and an idempotent repeat before normal reconciliation became durable.

Cilium provides IPv4 VXLAN networking, Kubernetes NetworkPolicy enforcement,
kube-proxy replacement, and Hubble flow visibility. Native routing, BGP, Cilium L2
announcements, and Cilium Gateway API remain disabled because MetalLB and Envoy Gateway
own those platform roles.

## Flux ownership and dependency graph

Flux is the sole reconciler for Kubernetes desired state. It follows the protected
Forgejo `main` branch over HTTPS using a repository-specific read-only identity and decrypts Kubernetes Secret values
with the in-cluster SOPS identity. No parallel Argo CD ownership or committed rendered
chart output exists.

The production root selects explicit child Kustomizations. Controllers are separated
from the custom resources that depend on them, and `dependsOn`, readiness waiting,
timeouts, health checks, and Helm remediation express rollout order and failure
behavior. The root uses orphan deletion behavior so loss of the root Kustomization does
not cascade into removal of live workloads.

The principal order is:

1. Bootstrap Talos and etcd.
2. Install Cilium from the tracked values.
3. Bootstrap Flux and its SOPS identity, then transfer Cilium ownership to Flux.
4. Reconcile platform controllers such as cert-manager, MetalLB, and Envoy Gateway.
5. Reconcile controller configuration, certificates, Gateways, routes, DNS, storage,
   monitoring, and application workloads through explicit dependencies.

## Networking, Gateway, DNS, and certificates

MetalLB advertises a bounded LAN pool in L2 mode. The shared internal Gateway requests
one address explicitly rather than relying on automatic allocation. Envoy Gateway owns
the Gateway API controller and a replicated internal data plane. Application namespaces
must opt into the controller and attach portable HTTPRoutes; applications do not receive
the Gateway's TLS private key.

The implemented DNS automation is internal only. ExternalDNS is constrained to the
internal Gateway, an internal audience annotation, and its permitted DNS zone. It talks
to the DNS provider through verified HTTPS using a reviewed public CA and does not skip
certificate validation. External or public service exposure is outside this platform
design and requires a separate threat model and ownership decision.

cert-manager uses ACME DNS-01 with a zone-scoped DNS credential to issue the internal
wildcard certificate. The issuer and certificate reconcile only after the controller and
encrypted credential exist. The platform keeps one production issuer for normal service;
temporary issuance experiments do not define a permanent parallel certificate path.

## Storage roles

Longhorn provides replicated block storage for application configuration and state.
Replica data lives on the dedicated Talos user volume. The default storage class uses two
replicas with hard node anti-affinity, which tolerates one node loss without pretending a
three-node cluster can sustain every multi-failure combination. Workloads using its
single-writer claims use `Recreate`, `ReadWriteOncePod`, or StatefulSet semantics as
appropriate so rollouts do not contend for the same volume.

The initial machine design allowed the Longhorn XFS volume to grow into most remaining
NVMe space. Before it held replicas, the design changed to a fixed cap so node-local
capacity remained available for scratch, transcode, and future local workloads. The
timing was load-bearing: XFS could grow but not shrink, so delaying the correction until
after Longhorn stored data would have required disruptive replica evacuation and volume
recreation.

Bulk media and downloads use SMB instead of Longhorn. These storage systems solve
different failure models: Longhorn provides replicated low-latency application state,
while SMB provides shared bulk capacity and cross-application filesystem semantics.
Longhorn backups target the external NAS with an encrypted credential and recurring
snapshot and backup jobs. The controller package and its configuration are dependency-
ordered so custom resources are not applied before their CRDs and controller are ready.

Replicas provide availability; they are not backups. Recovery must preserve this
distinction. Old system drives were a bounded rollback option during installation, but
they are not a continuing backup or the current recovery source. Current recovery uses
the tracked Talos inputs, operator-held secret identity, etcd procedures, Longhorn
snapshots or backups, and the independent recovery sequence below.

## Failure boundaries and validation gates

Bootstrap deliberately has a small imperative boundary, but every owner transition has
an explicit stopping condition:

- Preflight identifies the exact three target machines, verifies firmware and Secure
  Boot prerequisites, and proves the selected install media before any destructive
  action.
- Talos source and every rendered node configuration must pass strict validation before
  application. Generated output is evidence for the application step, not durable
  source.
- Bootstrap succeeds only with exactly three expected etcd members and no alarms. Node
  operations proceed one at a time so the cluster never intentionally loses quorum.
- Cilium must make the nodes Ready before Flux is introduced. Its guarded adoption is a
  one-time ownership transfer; later runs must be idempotent and must not create a
  second Helm owner.
- Flux must reconcile the expected revision before foundation controllers and their
  custom resources advance. Controller/CRD readiness precedes dependent configuration.
- Networking and certificate foundations must pass before storage and applications.
  Storage provisioning and replica placement must pass before stateful workloads rely
  on them.
- Each disruptive experiment includes cleanup and recovery before the next disruption.
  A failed cleanup, an etcd alarm, or loss of expected ownership stops progression.

These gates preserve the useful method from the original phased rebuild without making
old phase names, shell transcripts, or rollout ceremony part of the design.
The foundation was accepted only after rolling-node recovery, TPM auto-unlock and etcd
recovery, MetalLB failover, Flux-controller recovery, and Git-driven workload
remove/recreate tests were followed by a sustained soak. This combined gate recognized
that isolated rollout success is weaker evidence than recovery followed by stable
operation over time.

Implementation revealed several non-obvious constraints:

- One storage bridge did not expose the preferred disk telemetry. A waiver was accepted
  only after native-drive evidence and repeated I/O checks established the narrower
  hardware claim; the waiver does not generalize to other devices.
- Etcd membership had to be asserted as an exact set. Merely observing three healthy
  endpoints could miss an unintended fourth or stale member.
- Removing the control-plane load-balancer exclusion belongs in Talos source because an
  ad hoc Kubernetes label edit would not survive machine reconciliation.
- Namespace-label changes used by Gateway admission can be delayed by controller cache
  behavior, so acceptance must observe the resulting attachment rather than assume an
  immediate label effect.
- A single-replica application with a `ReadWriteOnce` claim can deadlock under
  `RollingUpdate`; `Recreate` or StatefulSet ownership is a platform invariant.
- A node-level vulnerability collector that expects a conventional mutable host cannot
  be assumed compatible with Talos. The implemented security scanner omits that
  incompatible collector rather than weakening the host.
- Applying custom resources before their controller and CRDs are ready creates noisy or
  failed reconciliation. Package/configuration separation and dependency checks are
  therefore recovery behavior, not only repository style.

## Reconciled platform versions

The implemented design was reconciled against the repository pins as follows:

| Component | Version |
| --- | --- |
| Talos Linux machine configuration | `v1.13.6` |
| Kubernetes | `v1.35.6` |
| Talos client | `1.13.7` |
| Cilium chart | `1.19.6` |
| Flux | `2.9.2` |
| cert-manager | `v1.21.0` |
| MetalLB chart | `0.16.1` |
| Envoy Gateway | `v1.8.2` |
| ExternalDNS application / chart | `v0.21.0` / `1.21.1` |
| Longhorn chart | `1.12.0` |

This table records the original reconciliation, not a second current version inventory.
[`talos/talconfig.yaml`](../../talos/talconfig.yaml), Kubernetes manifests, `.mise.toml`,
and `mise.lock` own current pins. A later upgrade must follow an approved
upgrade design and update all coupled pins and validation together; this record does not
authorize independent Talos, Kubernetes, or Cilium upgrades.

## Validated outcomes

The greenfield platform demonstrated the intended boundaries through source and live
acceptance:

- Talhelper inputs and all rendered node configurations passed strict metal validation
  without tracking generated credentials.
- All nodes booted through Secure Boot, formed the three-member etcd quorum, and
  scheduled workloads.
- TPM-bound `STATE` and `EPHEMERAL` volumes unlocked after rolling node reboots, and each
  node rejoined etcd and the platform health gates.
- Cilium, kube-proxy replacement, Hubble, network policy, and the applicable functional
  connectivity cases passed before Flux adoption.
- Flux reconciled the tracked source, decrypted a non-sensitive SOPS canary, adopted the
  existing Cilium release, and resumed reconciliation after controller restart.
- The internal path from DNS through trusted TLS, Gateway API, and application routes
  passed as a complete foundation check.
- Longhorn provisioning, two-node replica placement, claim attachment, backup-target
  availability, and recurring snapshot and backup configuration passed the storage
  acceptance checks. The retained acceptance record did not prove a backup restore or a
  post-reboot replica rebuild.

These outcomes establish architecture, not a promise that the live cluster is currently
healthy. Current status and recovery use the repository's scoped verification workflows
and the independent recovery sequence below.

## Reconsideration boundaries

Cilium L2 or BGP can replace MetalLB only after stable operation and a measurable
benefit justify moving ownership. A secret controller becomes appropriate when actual
rotation, external-secret, or multi-cluster pressure outweighs its new credential and
availability surface. Shared application bases should be introduced only when the
deferred Pi staging cluster creates real duplication and establishes a stable
abstraction. That staging cluster can validate application composition, chart and
Kustomize behavior, and multi-architecture compatibility. It cannot validate Talos,
Secure Boot, x86 GPU behavior, or production storage performance and recovery.
Automated lifecycle management requires successful manual upgrade and rollback evidence
first.

External or public service exposure, another reconciler, another CNI, and any change to
the Talos, Kubernetes, or Cilium compatibility set require a new design decision. This
historical specification does not authorize them. Current procedures and compatibility
constraints remain in repository policy, pinned source, and the recovery sections below.

## Consequences

The repository plus the operator-held age identity can recreate the Talos and Kubernetes
source of truth. Flux owns steady-state Kubernetes delivery after the explicit Talos and
Cilium bootstrap boundary. Platform components have one owner, dependency order is
declarative, and storage, ingress, DNS, certificate, and secret responsibilities remain
separate enough to recover or replace independently.

## External DNS recovery

Pi-hole and Unbound are external infrastructure; installation, backup, host authority,
and restore remain outside this repository. ExternalDNS uses a dedicated Pi-hole
application password over verified HTTPS with the reviewed public CA. Private TLS keys
stay on the Pi-hole host. Application-password configuration authority is broader than
DNS-record updates, so this credential is dedicated to ExternalDNS.

After an external rebuild, restore the expected hostname and HTTPS listener, review SSH
host identity, and enable `webserver.api.app_sudo` for application-password writes.
A new application password invalidates the previous password and sessions; rotation has
an interruption until Git reconciliation replaces the ExternalDNS process. A new CA
must be reviewed through `mise exec -- just repo pihole-ca-refresh`; never bypass TLS
verification. The combined `foundation-provider-secrets` writer needs both provider
values, tests a uniquely owned DNS record, and encrypts the result. If cleanup is
uncertain, remove only the exact record printed by the writer and prove its absence
before retrying. These are operator workflows using external host or secret authority.

The CA and ciphertext rollout stamps ensure the running process consumes new material.
`foundation-verify` must prove those deployed revisions and the DNS-to-trusted-HTTPS
path. Existing Pi-hole records survive an ExternalDNS outage; new records and updates
wait for recovery. `upsert-only` intentionally leaves stale records after source removal,
so deletion requires deliberate external cleanup.

A MetalLB transition that narrows one pool and adds an overlapping pool needs ordered
Kustomizations: Flux dry-runs additions against the old live range before applying its
narrowing, and the webhook rejects the overlap.

## Private Tailscale access

Git owns the Operator, shared ingress ProxyGroup, Connector, and encrypted OAuth
material. The operator owns external tailnet tags, policy, route approval, DNS, and
clients. Suspension in Git does not remove external devices or credentials. The
Kubernetes API proxy, exit-node behavior, and public Funnel are outside this design.
Proxy workloads need the privileged namespace for TUN/network capabilities; that label
alone does not grant those settings to every Pod.

Establish the intended tailnet and Mac/iPhone clients, review base access policy, then
prepare the Operator before private services or the optional lab Connector. The OAuth
client uses `tag:k8s-operator`, which owns `tag:k8s` and `tag:lab-router` for managed
proxies. Grant only the Operator-required read/write Services, Devices Core, and Auth
Keys scopes. The external policy must preserve application Service ownership and
advertiser relationships separately from device tags; [ntfy](007-ntfy-notification-architecture.md)
owns its application contract. Merge feature relationships into the current policy,
rather than replacing unrelated entries. Before a second human joins, replace
single-user `autogroup:member` grants with a reviewed group.

Private Services require MagicDNS and HTTPS certificates. Their certificate names enter
public Certificate Transparency logs, so names must contain no sensitive information.
OAuth rotation keeps the old client valid until the ciphertext-derived rollout stamp
restarts the Operator, verification passes, and a real client can use a representative
service; only then revoke the old client.

The lab Connector advertises only the DNS resolver and internal Gateway host `/32`
routes from [Connector source](../../kubernetes/apps/networking/tailscale-operator/subnet-router/connector.yaml).
Never widen these to LAN, Pod, or Service networks. In external policy, both routes need
`tag:lab-router` auto-approval, resolver grants for TCP/UDP DNS, and Gateway grants for
HTTPS. Add the resolver as a restricted nameserver for the lab domain; do not override
all client DNS. Check route approval on both Connector devices: reported Kubernetes
routes mirror configuration and cannot independently prove approval. All applications
share the Gateway address, so application authentication provides per-application access.

Off-LAN acceptance requires real Mac and cellular iPhone clients to prove split DNS,
Tailscale routing, trusted HTTPS, and application login; disconnecting Tailscale must
remove access. On-LAN acceptance must inspect routes too: a host `/32` can take
precedence over the connected LAN and depend on Connector health. Diagnose connection,
both route approvals, split DNS, DNS answer, Gateway, then the application. Migrations
add and accept the new resolver or VIP route, grant, and DNS path before retiring the old
path. Guarded suspended-source bootstraps preserve resources and re-suspend on failure;
they are exceptional operator actions, not routine rotation or restart.

## Forgejo source cutover and recovery

Flux reads Forgejo through authenticated, trusted HTTPS. Its credential is the
operator-managed `flux-system/flux-system-forgejo` Secret, with `username` and `password`
fields. The password is an access token restricted to this repository with only
`read:repository` scope. Confirm that restriction in Forgejo when creating or rotating
the token; successful fetching alone cannot prove read-only permission. See the
[Forgejo token contract](https://forgejo.org/docs/v15.0/user/authentication/token-scope/)
and [Flux HTTPS authentication](https://fluxcd.io/flux/components/source/gitrepositories/#basic-access-authentication).
SSH was rejected for normal operation because the existing trusted HTTPS endpoint serves
Git and avoids another listener and SSH host-key lifecycle. Preserve TLS verification;
certificate or DNS failures require repair of that prerequisite.

The source credential remains outside Git and SOPS application configuration. An agent
can prepare and validate desired state with its scoped observer credentials. Credential
creation, source probes that change cluster state, the first live cutover, bootstrap,
and recovery below are attended operator actions using operator-controlled credentials.
The separate SOPS decryption Secret and application dependency graph retain their roles.
Keep the previous SSH Secret until acceptance and rollback retention are complete.

### Prepare and prove source access

Review and merge the source migration through the repository's required validation and
merge-authorization gates. Freeze merges to Forgejo main during cutover. A Forgejo-only
merge cannot reach Flux while Flux still watches GitHub; do not wait for it to do so.
From a clean checkout containing the reviewed Forgejo main revision, fetch `origin` and
confirm its URL matches the committed source. Run `mise exec -- just kube flux-preflight`.
This checks publication and platform prerequisites; it does not prove the Flux credential.

The operator creates a repository-specific read-only token and stores the username and
token in owner-readable files outside every checkout, without trailing newlines. Set
`FLUX_USERNAME_FILE` and `FLUX_TOKEN_FILE` to their absolute paths. Disable shell tracing.
After confirming the namespace and target name, create the credential without putting
its values in arguments or terminal output:

```bash
mise exec -- kubectl --kubeconfig .kube/config -n flux-system create secret generic flux-system-forgejo \
  --from-file=username="$FLUX_USERNAME_FILE" --from-file=password="$FLUX_TOKEN_FILE" \
  --dry-run=client -o yaml |
  mise exec -- kubectl --kubeconfig .kube/config apply -f -
unset FLUX_USERNAME_FILE FLUX_TOKEN_FILE
```

Retain the credential through the operator's independent recovery store; remove temporary
plaintext files after use. Replacing an existing credential requires an attended rotation.
Do not use the workstation's Git write credential for Flux.

Create a temporary GitRepository with no application consumers to prove access from
source-controller itself, including cluster DNS, routing, TLS, and authentication:

```bash
git fetch origin main
revision="$(git rev-parse origin/main)"
test "$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')" = "$revision"
mise exec -- flux create source git flux-forgejo-preflight \
  --namespace flux-system --url=https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos.git \
  --branch=main --commit="$revision" --secret-ref=flux-system-forgejo --export |
  mise exec -- kubectl --kubeconfig .kube/config apply -f -
mise exec -- flux reconcile source git flux-forgejo-preflight \
  --namespace flux-system --kubeconfig .kube/config --timeout 5m
mise exec -- kubectl --kubeconfig .kube/config -n flux-system get gitrepository flux-forgejo-preflight \
  -o 'custom-columns=GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration,READY:.status.conditions,REVISION:.status.artifact.revision'
```

First prove that the temporary resource name is absent; if it exists, establish ownership
before reusing or removing it. Require Ready for the current generation and the exact
intended commit in its artifact revision. Stop on failure; do not switch production or
weaken authentication/TLS to bypass it. This probe fetches Git only and applies no apps.

### Attended cutover and acceptance

Before any production mutation, save the live GitRepository's API version, kind, name,
namespace and complete spec to an owner-readable off-checkout rollback file. Save the
previous artifact revision and root Kustomization's suspension state. Prove that the
previous source and its credential still work, retain an independent clone containing
that commit, and check that the previous host can serve it. Record the current application
Kustomization inventory and workload/pod UIDs and generations. Review the entire Kubernetes
diff from the deployed commit to `$revision`; approve any intended workload change and
stop on unintended deletions, template changes or dependency changes. Source migration
alone must not prune workloads or roll pods.

Set `ROLLBACK_DIR` to an absolute directory in independent operator storage. Require the
root and production source to be Ready and unsuspended; investigate a different state
before beginning this cutover. Save non-secret source and workload baselines:

```bash
umask 077
mise exec -- kubectl --kubeconfig .kube/config -n flux-system get gitrepository flux-system -o json |
  mise exec -- yq '{"apiVersion": .apiVersion, "kind": .kind, "metadata": {"name": .metadata.name, "namespace": .metadata.namespace}, "spec": .spec}' \
  > "$ROLLBACK_DIR/source.yaml"
mise exec -- kubectl --kubeconfig .kube/config -n flux-system get gitrepository flux-system \
  -o jsonpath='{.status.artifact.revision}' > "$ROLLBACK_DIR/revision"
mise exec -- kubectl --kubeconfig .kube/config -n flux-system get kustomizations -o json \
  > "$ROLLBACK_DIR/kustomizations.json"
mise exec -- kubectl --kubeconfig .kube/config get deployments,statefulsets,daemonsets,pods -A -o json |
  mise exec -- yq '[.items[] | {"kind": .kind, "namespace": .metadata.namespace, "name": .metadata.name, "uid": .metadata.uid, "generation": .metadata.generation}]' \
  > "$ROLLBACK_DIR/workloads.yaml"
```

Immediately before cutover, repeat the Forgejo main SHA check, source probe reconciliation,
current-generation readiness check, rollback prerequisite checks and workload-diff review.
If main advanced, restart preparation for that revision. The operator then suspends only
the root to prevent its previous source manifest from undoing the switch:

```bash
mise exec -- flux suspend kustomization flux-system --namespace flux-system --kubeconfig .kube/config
mise exec -- yq 'select(.kind == "GitRepository")' kubernetes/flux/clusters/prod/flux-system/gotk-sync.yaml |
  mise exec -- kubectl --kubeconfig .kube/config apply -f -
mise exec -- flux reconcile source git flux-system --namespace flux-system --kubeconfig .kube/config --timeout 5m
mise exec -- kubectl --kubeconfig .kube/config -n flux-system get gitrepository flux-system \
  -o 'custom-columns=GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration,READY:.status.conditions,REVISION:.status.artifact.revision'
```

Other application Kustomizations remain active and can consume the new artifact as soon
as it is fetched; the frozen revision and reviewed workload diff are therefore required
before the source switch. Require the Forgejo URL, new Secret reference, unpinned `main`
branch, current-generation Ready and artifact revision `main@sha1:$revision`. On success,
resume the root and allow normal polling to converge:

```bash
mise exec -- flux resume kustomization flux-system --namespace flux-system --kubeconfig .kube/config
mise exec -- just kube flux-verify "$revision"
mise exec -- just test record verification.flux
mise exec -- kubectl --kubeconfig .kube/config -n flux-system delete gitrepository flux-forgejo-preflight
```

Compare the saved inventories, workload generations and pod UIDs. Account for every change;
unexpected pruning or rollout fails acceptance even when Ready. The verifier checks the
source and all active application Kustomizations against the exact intended revision.
Retained acceptance must run from clean deployed main, and its evidence must describe
that revision. Confirm it remains main before recording. Candidate evidence is not live
acceptance. After lifting the merge freeze, use a separately reviewed harmless main change
(for example a non-secret annotation on the existing canary Kustomization) to prove normal
polling fetches and applies a new Forgejo revision without manual reconciliation. Record
verification again after that revision converges. Keep issue acceptance pending until
these live checks pass.

### Recovery without a working source

If cutover fails, leave the old Secret intact. Suspend `flux-system`, restore the saved
GitRepository spec with the operator kubeconfig, and reconcile that source. Require the
saved old revision and current-generation Ready before restoring the root's prior
suspension state. If the previous branch moved, temporarily pin the saved commit for
recovery and keep the root suspended so old Git cannot undo the pin. Restore the normal
branch reference only after reviewing the recovery revision. Do not delete application
Kustomizations, uninstall Flux or remove workloads to recover source access.

For the unchanged previous branch, use the saved source independently of Forgejo:

```bash
mise exec -- flux suspend kustomization flux-system --namespace flux-system --kubeconfig .kube/config
mise exec -- kubectl --kubeconfig .kube/config apply -f "$ROLLBACK_DIR/source.yaml"
mise exec -- flux reconcile source git flux-system --namespace flux-system --kubeconfig .kube/config --timeout 5m
mise exec -- kubectl --kubeconfig .kube/config -n flux-system get gitrepository flux-system \
  -o 'custom-columns=GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration,READY:.status.conditions,REVISION:.status.artifact.revision'
# Only after the saved old revision is Ready, restore the previously active root.
mise exec -- flux resume kustomization flux-system --namespace flux-system --kubeconfig .kube/config
```

If the previous source is unavailable, keep the root suspended and recover trusted
Forgejo HTTPS and its read-only Secret from independent operator storage, then repeat
the temporary-source proof and attended cutover from a reviewed clone. Cluster source
recovery requires the Kubernetes API and Cilium; restore those lower layers first.
For missing Flux controllers on an otherwise healthy cluster, provision the namespace
and source credential, then run `mise exec -- just bootstrap flux` with its printed
confirmation after preflight. It applies the committed controller and source manifests
from published main without a Git write token. For a new cluster, continue the existing
SOPS setup and staged Cilium adoption before final Flux verification.

## Independent platform recovery

Recover the lowest unhealthy layer first: Talos/etcd, Cilium, Flux source access, Flux
SOPS decryption, then storage and applications. Checks can fail because their prerequisite
is unavailable; that identifies the recovery boundary and does not authorize skipping it.
Workstation loss with a healthy cluster requires only local recovery, not reinstall or
bootstrap. Administrator recovery uses an operator-controlled primary checkout; never
copy its credentials to a linked task worktree.

Independent prerequisites are a reviewed current clone, pinned tools, the matching
operator-held age identity, tracked encrypted Talos identity, and off-cluster backup
access. Keep private recovery roots outside all checkouts and independent of the cluster
or credential broker being recovered. Review configuration before `mise trust`, install
with `mise install --locked`, and use repository hooks and source validation.

With `SOPS_AGE_KEY_FILE` pointing to an owner-readable identity outside the checkout,
the operator restores local state in this order:

```bash
mise exec -- just repo secrets
mise exec -- just talos generate
# Retrieve administrator Kubernetes configuration only once an API is reachable.
mise exec -- just talos kubeconfig
```

Unset the identity environment reference after use. `repo secrets` proves recipient
agreement with `.sops.yaml`, not application credential validity. Generated machine
files and client configs are disposable; the age identity and encrypted Talos bundle
are not. Missing or mismatched identity is a stop boundary. Never regenerate the Talos
bundle or reuse legacy ciphertext to bypass loss of the matching identity.

Diagnose with `cluster status`, `talos volume-status`, and the Cilium/Flux/foundation
status workflows that are reachable. The following guarded recovery branches are
operator-run; invoke them without guessing confirmation and use only their printed exact
target-bound guard after reviewing the current preflight:

- Failed initial non-bootstrap etcd join: `mise exec -- just bootstrap retry-join <node>`
  proves failed service, absent membership, and exact discovery before one-node reboot.
  It requires the Kubernetes API for shared Lease coordination and fails closed without
  it. Success requires the requested join, exact healthy expected membership, one leader,
  and no alarms. Lost quorum, snapshot restoration, member removal, and replaying etcd
  bootstrap require a separate reviewed recovery plan.
- Maintenance-mode reinstall: `mise exec -- just talos apply <node>` wipes the target
  system disk. Prove survivor quorum, target hardware/Secure Boot/disk identity, and an
  off-target healthy replica or verified backup first. Reinstall only one node and prove
  its complete recovery before disturbing another. Live no-reboot source changes use
  `talos apply-live`, never this install path. Firmware, key enrollment (`Enroll Secure
  Boot keys: auto`), approved USB boot, and physical power remain operator actions. For
  KVM input, nuc2 requires the rear USB-C port via adapter; its rear USB-A path does not
  supply working input. nuc1/nuc3 use rear USB-A.
- Cilium before Flux ownership: `mise exec -- just bootstrap cilium` uses the canonical
  tracked values and rejects competing/unmanaged ownership. Once the Flux HelmRelease
  exists, repair through Git; never install a second owner or remove the only CNI as a
  workaround. Failed adoption restores the source edit and re-suspends resumed live
  reconciliation. If broken networking prevents Flux-owned repair, stop for a separately
  reviewed recovery plan; the repository has no parallel-owner shortcut.
- Flux source access: restore the operator-managed Forgejo credential and trusted HTTPS
  access using [the source procedure](#forgejo-source-cutover-and-recovery). Missing
  controller/bootstrap state uses `kube flux-preflight` followed by `bootstrap flux`.
  Bootstrap applies reviewed manifests from published Git; it does not write to Git or
  generate deploy keys. Remove the confirmation after recovery.
- Missing Flux decryption identity: `mise exec -- just bootstrap flux-sops` validates the
  workstation recipient, leaves a matching Secret unchanged, and requires its exact guard
  to create an absent Secret. A different live recipient is refused: preserve identities
  and ciphertext and design reviewed rotation/re-encryption instead of overwrite.

The permanent noncritical Flux canary has an encrypted marker and depends on Cilium.
`flux-verify` checks readiness; the separately authorized `flux-canary-test` deletes only
the labeled canary and proves recreation with a different UID. Routine observation does
not use that mutation. Neither source validation nor Ready state alone establishes full
platform recovery.

A returned node with lifecycle annotation and cordon remains contained. Resume through
[common node recovery](025-node-lifecycle-and-maintenance.md#recovery-acceptance), leaving
annotation removal and uncordon until final acceptance. Never manually uncordon a failed
recovery or downgrade code while lifecycle state still requires its interpreter.

Longhorn replicas provide availability, not backups. Let a returned node converge to
healthy redundancy before the next disruption. For lost application state, identify its
Git contract, select a verified backup, restore a **new** claim, and validate it with an
isolated workload before an explicitly authorized production replacement. The repository
checks backup target/configuration but does not automate claim restore or prove restored
application data. Flux Ready and storage readiness cannot establish retained history.

Recover application identity and data together using the owning contracts:
[media](006-media-stack-architecture.md), [n8n](023-n8n-workflow-automation-platform.md),
[automation-data](026-automation-data-postgresql-platform.md),
[NocoDB](028-nocodb-operator-ui.md), and [OpenBao](030-openbao-kubernetes-credential-broker.md).
Recover optional consumers only after their database or credential provider is accepted.
Finish with `cluster verify`, the Cilium/Flux/foundation/storage verifiers, and each
recovered application's functional acceptance. Preserve sanitized evidence through the
[reporting contract](011-test-reporting-standard.md); no recovery guard grants new authority.

## Scoped credential design

Linked worktrees begin without credentials. Approved Kubernetes access uses OpenBao
exec profiles; Talos reader installation remains a separate guarded workflow.
[Agent credential design](031-openbao-agent-credential-profiles.md) owns the shared
workstation trust boundary, server-side authorization, and independent recovery limits.
