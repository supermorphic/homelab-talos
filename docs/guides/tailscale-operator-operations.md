# Operate the Tailscale Kubernetes Operator

The Tailscale Kubernetes Operator connects selected Kubernetes resources to the private
tailnet. This guide owns the Operator, its OAuth credential, and the shared high-
availability ingress `ProxyGroup`. Application-specific exposure and subnet routing have
their own guides.

## Operator model

```text
Git → Flux
      ↓
Tailscale Kubernetes Operator
      ↓
HA ingress ProxyGroup (`ingress-proxies`, 2 replicas)
      ↓
app-specific Tailscale Service
      ↓
authorized tailnet client
```

The Operator watches Kubernetes objects and uses the Tailscale API to create and manage
tailnet devices and Services. The ProxyGroup supplies a reusable pool of ingress proxies;
each application still owns its own `Ingress`, service tag, access policy, and acceptance
test.

The Tailscale control plane remains external to this repository. It owns devices, OAuth
clients, tags, Access controls, Tailscale Services, approvals, and certificates. Git owns
the Kubernetes desired state and the SOPS-encrypted OAuth credential.

## What this guide owns

Git owns:

- the pinned Tailscale Operator HelmRelease;
- the `tailscale` namespace and its Pod Security admission labels;
- the Operator configuration and disabled Kubernetes API server proxy;
- `ProxyGroup/ingress-proxies` with two replicas;
- the SOPS-encrypted `Secret/operator-oauth`; and
- the ciphertext-derived Operator rollout stamp.

External Tailscale state owns:

- the OAuth client created in **Trust credentials**;
- `tag:k8s-operator` and `tag:k8s` ownership in **Access controls**;
- the Operator and proxy devices shown under **Machines**; and
- application-specific Tailscale Services shown under **Services**.

The tailnet policy is not tracked as an executable repository artifact. The fragment in
this guide defines only the Operator foundation. The
[ntfy guide](ntfy-operations.md) owns `tag:ntfy`; the
[lab-domain guide](tailscale-lab-domain-access.md) owns `tag:lab-router` and subnet-route
permissions.

## Pod Security boundary

The `tailscale` namespace uses the `privileged` Pod Security admission level. Operator-
created proxy workloads need `/dev/net/tun` and elevated network capabilities such as
`NET_ADMIN`. The namespace label allows Pods to request those settings; it does not add
the device or capabilities to every Pod automatically. Each generated workload still
defines its own security context.

This repository keeps the Kubernetes API server proxy disabled with
`apiServerProxyConfig.mode: "false"`. The Operator therefore does not create a tailnet
administration path into the Kubernetes API.

## When operator action is needed

| Situation | Action |
| --- | --- |
| Normal operation | None; Flux, the Operator, and the ProxyGroup reconcile continuously |
| Operator or ProxyGroup source change | Validate, publish through Git, let Flux reconcile, then verify |
| OAuth credential replacement | Create a replacement client, rewrite ciphertext and rollout stamp, publish, verify the restarted Operator, then revoke the old client |
| Deliberately suspended fresh/rebuilt Operator | Use the guarded Operator bootstrap |
| New private service | Follow the owning application's guide for its Ingress, tag policy, and client acceptance |
| Operator disablement | Suspend through Git, then separately review external devices, Services, tags, and credentials |

Current source is active with `spec.suspend: false`. Routine reconciliation, pod restart,
and OAuth rotation do not use the bootstrap workflow.

## Command effects and authority

| Command | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just repo tailscale-operator-secrets` | Writes SOPS ciphertext and its Operator rollout stamp | Operator-run repository credential mutation; requires plaintext OAuth values and the operator-held age identity |
| `mise exec -- just kube tailscale-operator-validate` | Validates source, render, dependency, Secret, rollout, security, ProxyGroup, and alert contracts | Local, read-only, agent-owned |
| `mise exec -- just kube tailscale-operator-verify` | Observes the live Operator and ProxyGroup, then runs the shared foundation verifier | Approved scoped observer verification; agent-autonomous when the task needs it |
| `mise exec -- just bootstrap tailscale-operator` | Resumes and reconciles a deliberately suspended deployment | Exceptional privileged live mutation; operator-run unless explicitly authorized for that invocation |
| Admin Console policy or OAuth change | Changes external tailnet security state | Operator-managed external mutation |

A confirmation environment variable is an execution guard. It makes the exact target
and intent explicit; it does not decide authority by itself.

## Configure the Operator tag relationship

In **Access controls**, merge this foundation into the current policy:

```jsonc
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s": ["tag:k8s-operator"]
}
```

The Operator device receives `tag:k8s-operator`. It must own `tag:k8s` so it can create
the shared ProxyGroup devices with that tag. The OAuth client must also be authorized to
use `tag:k8s-operator`.

Do not add application access grants here. A ProxyGroup device tag and a Tailscale
Service tag are different policy roles in the current HA Service model. Application
guides define who may reach each advertised Service. See Tailscale's current
[Operator tag documentation](https://tailscale.com/docs/kubernetes-operator/reference/tags)
and [Operator permission model](https://tailscale.com/docs/kubernetes-operator/reference/rbac).

## Create the OAuth client

Open **Trust credentials** in the Tailscale Admin Console and create an OAuth client for
this cluster. Give it `tag:k8s-operator` and read/write access to:

| Area | Scope |
| --- | --- |
| General | Services |
| Devices | Core |
| Keys | Auth Keys |

These are the current Tailscale-documented Operator permissions. They let the Operator
manage Tailscale Services and devices and create the auth keys needed for itself and its
managed resources. Do not grant the catch-all API scope.

Store the client ID and client secret securely. The secret is long-lived until revoked
and must not appear in Git, shell history, chat, logs, or documentation. See the current
[Operator installation](https://tailscale.com/docs/kubernetes-operator/install-operator)
and [Trust credentials](https://tailscale.com/docs/reference/trust-credentials)
documentation for the Admin Console terminology.

## Write the encrypted OAuth Secret

Load the repository age identity and run this from the authorized feature worktree:

```bash
TS_OAUTH_CLIENT_ID='<client-id>' \
TS_OAUTH_CLIENT_SECRET='<client-secret>' \
TAILSCALE_OPERATOR_SECRETS_CONFIRM='write:networking:tailscale-operator:sops' \
  mise exec -- just repo tailscale-operator-secrets
```

The guarded writer:

1. verifies the loaded age identity;
2. validates the OAuth client-secret format;
3. writes only SOPS ciphertext to
   `kubernetes/apps/networking/tailscale-operator/app/oauth.sops.yaml`;
4. hashes that ciphertext into `operatorConfig.podAnnotations.sops-hash`; and
5. verifies that the stored stamp matches the encrypted file.

The rollout stamp matters because Operator 1.98.9 reads the mounted OAuth client ID and
secret once when the process starts. A Secret update alone changes the mounted files but
does not make the running process rebuild its API client. The stamp changes the
Deployment pod template, so Flux and Helm replace the Operator Pod after a credential
change. The ProxyGroup Pods retain their own state and do not need an OAuth-driven
restart.

Review both ciphertext and values changes before committing them. Only ciphertext and a
non-secret Git object hash enter the repository.

## Validate source

Run:

```bash
mise exec -- just kube tailscale-operator-validate
```

This checks the pinned chart, Kustomization split and dependency order, SOPS wiring,
OAuth Secret shape, ciphertext rollout stamp, rendered Operator pod annotation,
privileged namespace declaration, disabled API server proxy, two-replica ingress
ProxyGroup, alert coverage, and Helm/Kustomize renders.

The validator does not contact the tailnet. It cannot prove that the OAuth client exists,
has the documented scopes, or may use the configured tags.

## Bootstrap a deliberately suspended deployment

Use bootstrap only when a fresh or rebuilt Operator has been intentionally staged with
the source Kustomization suspended. Publish that suspended source and encrypted Secret
through the normal pull-request path first. Then, from the authorized deployed-main
administrative path, run:

```bash
TAILSCALE_OPERATOR_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-operator' \
  mise exec -- just bootstrap tailscale-operator
```

The recipe verifies that the relevant local files match deployed `main`, checks both the
source and live Kustomization are suspended, validates source, resumes only the Operator,
waits for it, reconciles the dependent ProxyGroup, and runs live verification. If the
attempt fails after resume, cleanup re-suspends the Operator Kustomization while
preserving resources.

After attended acceptance, use a separate reviewed Git change to make
`spec.suspend: false` durable. Do not use bootstrap for routine rotation or restart.

## Verify the Operator and ProxyGroup

Run the approved scoped verifier:

```bash
mise exec -- just kube tailscale-operator-verify
```

### What it proves

- the `tailscale-operator` Flux Kustomization is Ready;
- the `tailscale-operator` HelmRelease is Ready;
- `Deployment/operator` completed its rollout;
- the dependent ProxyGroup Kustomization is Ready;
- `ProxyGroup/ingress-proxies` exists; and
- at least two `ingress-proxies` StatefulSet replicas are Ready.

The command then runs the shared foundation verifier, so a later failure can belong to a
different foundation subsystem even after every Tailscale-specific assertion passed.

### What it does not prove

- the OAuth client's current scopes or tag authorization;
- the tailnet Access controls policy;
- Tailscale Service auto-approval;
- application-specific Ingress configuration;
- a real tailnet client's HTTPS path;
- Connector route approval or split DNS; or
- that every application exposed through the ProxyGroup is usable.

Confirm the Operator device and two proxy devices in **Machines**. Prove the data path
through the first real application, not an ad-hoc production mutation. For ntfy, follow
the off-LAN acceptance in [ntfy operations](ntfy-operations.md).

## Expose a private application

An application uses the shared ingress pool by declaring an `Ingress` with:

- `ingressClassName: tailscale`;
- `tailscale.com/proxy-group: ingress-proxies`; and
- an application-specific `tailscale.com/tags` value.

The Operator creates a Tailscale Service and configures both ProxyGroup replicas as its
backends. The application's owning guide must also define:

- tag ownership;
- which ProxyGroup tag may advertise the Service;
- which tailnet identities may connect;
- HTTPS and application authentication requirements; and
- real client acceptance.

See Tailscale's [HA ingress documentation](https://tailscale.com/docs/kubernetes-operator/ingress)
for the upstream model. This repository's first implementation is ntfy.

## Rotate the OAuth credential

1. In **Trust credentials**, create a replacement OAuth client with the same three
   read/write scopes and `tag:k8s-operator` authorization.
2. Keep the old client active during rollout.
3. Run `tailscale-operator-secrets` with the replacement values.
4. Run source validation and `mise exec -- just ci`.
5. Review, commit, and merge the ciphertext and rollout-stamp changes.
6. Let Flux reconcile. The changed pod annotation replaces the Operator Pod so it reads
   the new credential.
7. Run `tailscale-operator-verify` and confirm the Operator remains present in
   **Machines** and the application Services remain connected.
8. Repeat a representative app-specific client acceptance test.
9. Revoke the old OAuth client only after those checks pass.

Do not revoke the old client before the replacement Operator is verified. Do not patch
the live Secret or use an ad-hoc rollout restart; the durable rollout trigger belongs in
Git.

## Disable or recover the Operator

To disable reconciliation, change the Operator Kustomization through Git. Flux
suspension does not remove external devices, policy, Services, or OAuth credentials.
Review those objects separately and remove only state that no remaining integration uses.

If the Operator must be rebuilt, preserve the current tailnet policy and valid OAuth
client, stage the guarded suspended-source lifecycle, and use bootstrap. Application-
specific recovery remains in the owning application guide. Connector recovery is in
[Lab-domain access over Tailscale](tailscale-lab-domain-access.md).
