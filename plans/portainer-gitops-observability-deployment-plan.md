# Portainer GitOps Observability Deployment Plan

## Goal

Deploy Portainer CE as an internal, read-only operational view of the Talos
Kubernetes cluster. Git and Flux remain the source of desired state; Portainer
must not become a deployment authority.

The current milestone is **Phase 1: in-cluster Kubernetes viewing only**.
Standard Agents on Pi Docker hosts are deferred to a separately approved
Phase 2 and do not block the Server rollout.

## Phase 1 Architecture

```text
Git main
   |
   v
  Flux
   |
   v
Portainer Server (portainer namespace)
   |-- read-only ServiceAccount --> Kubernetes API
   |-- Longhorn RWO PVC ----------> /data
   `-- ClusterIP :9000 -----------> internal HTTPS Gateway
```

Portainer is available only at:

```text
https://portainer.lab.supermorphic.com
```

There is no NodePort, LoadBalancer, public route, Edge tunnel, Docker Agent,
`AGENT_SECRET`, or database-encryption key in Phase 1.

## Decisions

- Use Portainer CE `2.39.5` and official Helm chart `239.5.0`.
- Place the application under `kubernetes/apps/monitoring/portainer`.
- Stage the Flux Kustomization with `suspend: true`, matching every existing
  guarded application rollout in this repository.
- Generate the SOPS-encrypted administrator Secret before the staging PR.
- Use `localMgmt: false` so the chart does not render its `cluster-admin`
  binding.
- Patch the rendered Deployment to use the repository-owned
  `portainer-readonly` ServiceAccount. Chart `239.5.0` omits
  `serviceAccountName` when `localMgmt` is false.
- Set `createNamespace: false`; the repository owns the Namespace and its
  Gateway/Pod Security labels.
- Patch the rendered Service to retain only port 9000.
- Use a retained 5 Gi Longhorn RWO PVC and the chart's `Recreate` Deployment.
- Configure the 2.39.x trusted-origin value as
  `portainer.lab.supermorphic.com`. Re-evaluate the required full-URL format
  before upgrading to Portainer 2.41 or later.
- Defer database encryption.
- Pin images by versioned tag, matching the repository's current workload image
  convention; digest pinning requires a separate repository-wide contract.

## Kubernetes Security Boundary

Create a custom ServiceAccount, ClusterRole, and ClusterRoleBinding. Permit only
`get`, `list`, and `watch` for:

- core workload, node, namespace, service, event, configuration, and storage
  inventory;
- Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs, and HPAs;
- Kubernetes networking, discovery, storage, policy, and RBAC metadata;
- metrics-server data;
- Gateway API resources;
- Flux Kustomization, HelmRelease, and source resources;
- selected Longhorn inventory; and
- pod logs with `get`.

Never grant:

- Secret access;
- wildcard API groups, resources, or verbs;
- `create`, `update`, `patch`, `delete`, bind, escalate, or impersonate; or
- pod exec, attach, or port-forward.

Conftest policy and live `kubectl auth can-i --as=...` checks enforce this
boundary. The Kubernetes API—not visible UI buttons—is authoritative.

Add a CiliumNetworkPolicy that allows:

- Envoy Gateway to Portainer TCP 9000;
- node health probes to pod TCP 9443;
- Portainer to the Kubernetes API; and
- Portainer to CoreDNS.

All other ingress and egress remain denied in Phase 1.

## Credentials

The guarded `just repo portainer-secrets` recipe creates the encrypted
`portainer-admin-password` Secret from `PORTAINER_ADMIN_PASSWORD`. The operator
must provide the repository age identity and exact
`PORTAINER_SECRETS_CONFIRM` value.

The password file initializes the first administrator only. Updating the Secret
does not rotate an administrator already stored in the Portainer database.
Routine rotation must use Portainer's supported password-change/reset procedure,
then regenerate the encrypted bootstrap Secret so disaster recovery uses the
current credential.

No plaintext credential, age private key, decrypted Secret, or database content
may appear in Git, output, tests, or documentation.

## Delivery

### Staging PR

Include:

- this plan;
- suspended Flux Kustomization;
- Namespace, HelmRepository, HelmRelease, values, RBAC, HTTPRoute, and Cilium
  policy;
- SOPS-encrypted administrator Secret;
- secret-generation, validation, live verification, persistence, and bootstrap
  recipes;
- Conftest policy tests;
- Chainsaw read-only smoke coverage; and
- the Portainer operations runbook.

Before opening the PR:

1. Generate the encrypted Secret.
2. Inspect the ciphertext-only diff.
3. Run `mise exec -- just ci`.
4. Confirm the branch is based on current `origin/main`.

After merge, the operator runs:

```bash
PORTAINER_BOOTSTRAP_CONFIRM='bootstrap:portainer' \
  mise exec -- just bootstrap portainer
```

The recipe validates deployed source, confirms the live Kustomization is
suspended, resumes it, reconciles it, runs live acceptance, and re-suspends on
failure while preserving created resources.

Then run the independently guarded persistence proof:

```bash
PORTAINER_PERSISTENCE_CONFIRM='recreate:portainer:pod:preserve-pvc' \
  mise exec -- just kube portainer-persistence-test
```

### Activation PR

After live acceptance:

- change the Portainer Flux Kustomization to `suspend: false`;
- add the Gatus HTTPS endpoint;
- add Prometheus alerts for sustained probe failure, missing probe data, and an
  absent/unbound PVC;
- run `just ci`; and
- squash-merge only after the CI status is green.

Run `just kube portainer-verify` and
`just test smoke platform portainer` after Flux reconciles.

## Phase 1 Acceptance

Phase 1 is complete when:

- Flux Kustomization and HelmRelease are Ready;
- the Deployment is Available with one replica, `Recreate`, and
  `portainer-readonly`;
- the PVC is Bound on Longhorn, retained, and covered by the existing daily
  recurring jobs;
- the Service exposes only ClusterIP port 9000;
- the HTTPRoute is Accepted with ResolvedRefs and trusted HTTPS works;
- Portainer displays all Talos nodes, expected workloads, events, and pod logs;
- Secret and mutation authorization checks are denied;
- the Cilium policy permits only the documented paths;
- pod recreation preserves the PVC UID and UI state; and
- Portainer loss has no effect on Flux-managed workloads.

## Deferred Phase 2

Do not implement any Pi setup in Phase 1.

When separately approved, Phase 2 will use standard Portainer Agents on the LAN,
not Edge Agents. The Pi repository will own the matching-version containers,
Docker socket/volume mounts, restart policy, and host firewall configuration.
This repository will add a separately stored SOPS `AGENT_SECRET` and narrowly
extend Portainer egress.

Before hard-coding firewall sources:

1. Deploy a disposable Agent with logged temporary rules.
2. measure the observed connection source from workloads scheduled on each
   Talos node;
3. apply the final allowlist for TCP 9001; and
4. test incorrect-secret rejection against the disposable Agent.

With `AGENT_SECRET`, the Agent accepts Server connections presenting the same
secret and does not rely on first-claim ownership. `/ping` proves reachability,
not authentication.

Portainer CE cannot enforce a Docker read-only role. Standard Agents therefore
carry host-level Docker authority, while Ansible/Compose remain the procedural
source of desired state.
