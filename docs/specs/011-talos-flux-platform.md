# Talos and Flux Platform

## Purpose

Define the rebuildable architecture for the three-node Talos Linux and Flux GitOps
Kubernetes platform. The design joins machine configuration and cluster desired state in
one repository so changes that cross the operating-system and Kubernetes boundary remain
reviewable together.

## Greenfield rebuild

The replacement system drives were introduced before the cluster held workloads or
durable application data. Preserving the earlier Talos identity and migrating its etcd
state would have added recovery risk without preserving useful state. The platform was
therefore rebuilt with a fresh Talos identity and a new source-controlled configuration.
The previous installation was useful as hardware, firmware, Secure Boot, and rollback
evidence, but not as a configuration source.

This choice established a reproducible source of truth and avoided carrying forward
legacy controllers, credentials, generated machine files, or unverified ciphertext.

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
Application credentials on that volume remain independently protected through SOPS and
application controls.

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

Internal and public DNS automation are separate by provider, credential, zone, and
exposure policy. The implemented internal ExternalDNS controller is constrained to the
internal Gateway, an internal audience annotation, and its permitted DNS zone. It talks
to the DNS provider through verified HTTPS using a reviewed public CA and does not skip
certificate validation.

cert-manager uses ACME DNS-01 with a zone-scoped DNS credential to issue the internal
wildcard certificate. The issuer and certificate reconcile only after the controller and
encrypted credential exist. The platform keeps one production issuer for normal service;
a staging issuer is temporary test material for an explicit issuance experiment, not a
permanent parallel certificate path.

## Storage roles

Longhorn provides replicated block storage for application configuration and state.
Replica data lives on the dedicated Talos user volume. The default storage class uses two
replicas with hard node anti-affinity, which tolerates one node loss without pretending a
three-node cluster can sustain every multi-failure combination. Workloads using its
single-writer claims use `Recreate`, `ReadWriteOncePod`, or StatefulSet semantics as
appropriate so rollouts do not contend for the same volume.

Bulk media and downloads use SMB instead of Longhorn. These storage systems solve
different failure models: Longhorn provides replicated low-latency application state,
while SMB provides shared bulk capacity and cross-application filesystem semantics.
Longhorn backups target the external NAS with an encrypted credential and recurring
snapshot and backup jobs. The controller package and its configuration are dependency-
ordered so custom resources are not applied before their CRDs and controller are ready.

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

[`talos/README.md`](../../talos/README.md),
[`kubernetes/README.md`](../../kubernetes/README.md), `.mise.toml`, and `mise.lock`
remain the operational compatibility sources. A later upgrade must follow an approved
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
- Longhorn provisioning, replica placement, claim attachment, snapshot and backup
  configuration, and recovery behavior passed the storage acceptance checks.

These outcomes establish architecture, not a promise that the live cluster is currently
healthy. Current status and recovery use the repository's scoped verification workflows
and runbooks.

## Consequences

The repository plus the operator-held age identity can recreate the Talos and Kubernetes
source of truth. Flux owns steady-state Kubernetes delivery after the explicit Talos and
Cilium bootstrap boundary. Platform components have one owner, dependency order is
declarative, and storage, ingress, DNS, certificate, and secret responsibilities remain
separate enough to recover or replace independently.
