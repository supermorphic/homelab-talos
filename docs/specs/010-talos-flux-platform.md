# Talos and Flux Platform

## Purpose

Define the rebuildable architecture for the three-node Talos Linux and Flux GitOps
Kubernetes platform. The design joins machine configuration and cluster desired state in
one repository so changes that cross the operating-system and Kubernetes boundary remain
reviewable together.

The tracked machine and Kubernetes configuration owns exact implementation facts. This
specification owns platform boundaries and the independent recovery path.

## Architectural choices

One monorepo keeps machine, bootstrap, networking, and application compatibility changes
reviewable together. HomeOps supplies selected patterns, not a wholesale template or
legacy deployment input: imported providers, identities, layout, and release cadence
would create unwanted ownership and maintenance assumptions. Talhelper is the sole
renderer, preventing divergent credential-bearing hand-maintained machine files.

Three uniform schedulable control planes give an odd etcd quorum without a second node
class. Each platform responsibility has one owner: Cilium for CNI/kube-proxy and policy,
MetalLB for service advertisement, Envoy Gateway for Gateway API, and Flux for delivery.
Parallel CNI, ingress, or reconciler ownership would complicate recovery and is unsupported.

Longhorn supplies replicated application state; SMB supplies shared bulk capacity.
Local-only state cannot meet rescheduling goals, making all state NAS-dependent weakens
ordinary availability, and Ceph adds disproportionate complexity at this scale. SOPS
keeps encrypted desired state reviewable without another in-cluster secret authority.
Manual observable lifecycle acceptance precedes automation; successful rollout alone is
weaker than recovery and stable subsequent operation.

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
`main` branch using a read-only deploy identity and decrypts Kubernetes Secret values
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

Longhorn volume sizing preserves node-local capacity for other workloads. XFS grows but
cannot shrink: reducing an established allocation requires replica evacuation and volume
recreation, not a harmless machine-size edit.

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
snapshots or backups, and the recovery procedure below.

## Failure boundaries and validation gates

Installation proves exact target hardware, firmware, Secure Boot, and media before any
destructive action. Tracked and rendered Talos inputs require strict validation. Etcd
acceptance requires the exact expected member set, a common leader, and no alarms:
three healthy endpoints alone can conceal stale or unintended membership. Disrupt only
one node at a time and complete recovery before advancing.

Cilium must make nodes Ready before Flux; guarded adoption must preserve the only CNI
and be idempotent. Flux must reconcile the intended revision, and controllers/CRDs must
be ready before dependent configuration. Networking/certificates precede storage and
applications; replica placement and provisioning precede stateful use. Failed cleanup,
alarm, or ownership drift stops progression. Observe Gateway attachment after namespace
label changes because controller caches can delay admission effects.

A single-replica `ReadWriteOnce` Deployment can deadlock under `RollingUpdate`; use
`Recreate` or StatefulSet semantics. Workload checks must render effective Helm workloads
rather than assume Kustomize includes chart-generated objects. Talos immutability must
not be weakened for a collector designed for mutable hosts.

## Compatibility boundary

[Machine source](../../talos/talconfig.yaml), [Cilium values](../../kubernetes/apps/kube-system/cilium/app/values.yaml),
[tool pins](../../.mise.toml), and [the lockfile](../../mise.lock) own exact versions.
Talos, Kubernetes, and Cilium are a coupled compatibility decision: Cilium replaces both
CNI and kube-proxy and depends on Talos networking and KubePrism. An approved upgrade
must validate the machine schema, client/server compatibility, Cilium's Kubernetes
support, extensions, and networking before applying coupled pin changes. A dependency
update alone does not authorize an independent platform upgrade.

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
specification does not authorize them; repository policy and pinned source govern execution.

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
- Flux SSH host trust only: `mise exec -- just bootstrap flux-ssh-known-hosts` repairs
  `known_hosts` for `knownhosts: key is unknown`, preserving the working deploy identity.
  Missing deploy identity/bootstrap state instead uses `kube flux-preflight` followed by
  `bootstrap flux` with a temporary repository-scoped GitHub credential. Remove that
  credential and confirmation after recovery; Flux retains only its read-only deploy key.
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
