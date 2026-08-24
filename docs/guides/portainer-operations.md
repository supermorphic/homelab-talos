# Operate and recover Portainer

Portainer CE provides an internal operational view of the Talos Kubernetes cluster at
`https://portainer.lab.supermorphic.com`. Use it to inspect workloads, events, metrics,
storage, and pod logs. Do not use it as a second deployment system.

Git defines the desired cluster state. Flux applies that state. Portainer observes the
result through a deliberately restricted Kubernetes identity.

## Mental model

```text
Human operator / Homepage
          ↓
       Portainer
          ↓
portainer-readonly ServiceAccount
          ↓
    Kubernetes API
          ↓
RBAC allows or denies each operation

Git → pull request → main → Flux
                       ↓
             desired-state authority
```

Portainer can display buttons that normally change Kubernetes resources. A visible
button does not grant permission. The Kubernetes API checks every request against RBAC,
and the `portainer-readonly` identity does not have normal mutation authority.

Do not create Portainer stacks, install Helm applications, change Flux-managed
resources, or perform ad-hoc Kubernetes administration through Portainer. If Portainer
is unavailable, Flux-managed workloads continue to run.

## What Git owns and what Portainer owns

Git and SOPS own Portainer's Deployment, chart version, route, network policy, RBAC,
retained-volume declaration, encrypted initial administrator Secret, and encrypted
Homepage API token. Flux reconciles that state after it reaches `main`.

Portainer stores its users, administrator password, access tokens, local-environment
record, and UI state in its database on the retained `portainer` PVC. The PVC-backed
database, not the initial administrator Secret, is authoritative for an existing
installation's live login state.

## Kubernetes authority boundary

The Portainer pod runs as the `portainer-readonly` ServiceAccount. Its ClusterRole
permits `get`, `list`, and `watch` for approved inventory, event, metric, RBAC metadata,
Gateway API, Flux, and Longhorn resources. It also permits `get` for pod logs.

The role does not grant:

- Kubernetes Secret-body access;
- create, update, patch, or delete verbs;
- pod exec, attach, or port-forward;
- bind, escalate, or impersonate;
- wildcard API groups, resources, or verbs.

The Cilium policy further limits Portainer's network paths to the internal Gateway and
node health probes for ingress, and the Kubernetes API plus cluster DNS for egress.
Standard Portainer Agents, Edge connectivity, Docker sockets, and external exposure are
not part of this deployment.

The authoritative permissions are in
`kubernetes/apps/monitoring/portainer/app/rbac.yaml`. The policy and live verifier test
that boundary independently of what the UI displays.

## Command effects and authority

A confirmation variable is an execution guard. The operation's effect and required
credentials determine who may run it.

| Operation | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just kube portainer-validate` | Renders and validates the source, chart, route, storage, network policy, monitoring, and RBAC | Local, read-only |
| `mise exec -- just kube portainer-policy-validate` | Applies the Portainer RBAC policy tests to the declared role and binding | Local, read-only |
| `mise exec -- just kube portainer-verify` | Compares the live deployment, route, storage, isolation, and effective RBAC graph with reviewed source | Approved scoped, read-oriented live verification |
| `mise exec -- just repo portainer-secrets` | Writes the SOPS-encrypted initial administrator password | Tracked credential mutation; operator-run because it needs plaintext input and the operator-held age identity |
| `mise exec -- just repo homepage-portainer-secrets` | Writes the encrypted Homepage API token and stamps its revision into the Homepage pod template | Tracked credential and Deployment mutation; operator-run because it needs plaintext input and the age identity |
| `mise exec -- just bootstrap portainer` | Temporarily resumes a deliberately suspended Portainer installation and runs live acceptance | Privileged live mutation; exceptional operator bootstrap |
| `mise exec -- just kube portainer-persistence-test` | Deletes the Portainer pod and proves that its replacement uses the same PVC | Deliberately disruptive live test; operator-run |
| Portainer password change | Changes the administrator credential in Portainer's retained database | Application-state mutation; operator-run |
| Portainer reset helper | Changes the retained Portainer database while the normal workload is stopped | Privileged recovery mutation; operator-run |
| Longhorn restore | Restores database state from a selected backup | Privileged storage recovery; operator-run |

The Portainer verifier is an approved observer-tier workflow. An agent may run it when
the assigned task needs scoped verification. The bootstrap, persistence, password, and
storage-recovery paths cross live mutation or elevated-credential boundaries and remain
operator actions.

## Normal operation

No routine Portainer action is required. Use the UI for read-oriented inspection and run
the verifier after relevant Portainer, RBAC, Gateway, or storage changes:

```bash
mise exec -- just kube portainer-verify
```

### What the verifier proves

- The Portainer Flux Kustomization and HelmRelease are Ready.
- The Deployment is rolled out with strategy `Recreate` and uses
  `portainer-readonly`.
- The Service exposes only the intended in-cluster HTTP port.
- The retained PVC is Bound, uses Longhorn, and has the Helm retention annotation.
- The live ClusterRole exactly matches the reviewed source.
- No additional direct Portainer binding or unsafe ambient authenticated-user binding
  broadens the ServiceAccount's authority.
- The Cilium policy exists.
- The HTTPRoute is accepted, its references resolve, internal DNS is correct, and the UI
  responds through trusted HTTPS.
- The pinned chart still renders the expected source and passes the offline RBAC policy.

### What the verifier does not prove

- that the operator knows the current administrator password;
- that every Portainer UI page works;
- that the Homepage token works or has the narrowest possible Portainer-level access;
- that the Portainer database contents are correct;
- that pod recreation preserves usable application state; use the separate persistence
  test for that deliberate disruption;
- that a Longhorn backup was recently restored and accepted.

The verifier does not attempt a forbidden production mutation. Its negative proof comes
from matching the complete live authorization graph to the reviewed role and binding,
then applying source policy that rejects Secrets, mutation, interactive pod operations,
and wildcards.

## Initialize an empty Portainer database

This section is for a genuine new or empty database. The current deployment is already
active and must not be treated as though it still needs bootstrap.

### Stage the installation through Git

Before starting an empty database:

1. In a feature worktree, set
   `kubernetes/apps/monitoring/portainer/ks.yaml` to `spec.suspend: true`.
2. Remove the Portainer Gatus endpoint in the same staged design. A suspended application
   must not create a deliberate monitoring failure.
3. Create the initial administrator Secret as described below.
4. Run the local validators, review the exact diff, and merge the suspended source and
   encrypted Secret through the normal pull-request path.
5. Wait for Flux to reconcile that suspended source before running the guarded
   bootstrap.

The bootstrap recipe verifies that its rollout-sensitive source matches published
`origin/main`, that both Git and the live Kustomization remain suspended, and that source
validation passes before it accepts the confirmation guard.

### Create the initial administrator Secret

Choose a unique password of at least 12 characters and store it in the password manager.
From the feature worktree that owns the encrypted change, load the repository SOPS age
identity without printing it and run:

```bash
printf 'Initial Portainer administrator password: '
read -rs PORTAINER_ADMIN_PASSWORD
printf '\n'
export PORTAINER_ADMIN_PASSWORD
export PORTAINER_SECRETS_CONFIRM='write:monitoring:portainer-admin:sops'

mise exec -- just repo portainer-secrets

unset PORTAINER_ADMIN_PASSWORD PORTAINER_SECRETS_CONFIRM
```

The recipe validates the loaded age identity, checks the minimum length, and writes only
`kubernetes/apps/monitoring/portainer/app/portainer-admin-password.sops.yaml`. It does not
print the password. Review only the encrypted diff.

The chart passes that Secret through `--admin-password-file`. Portainer uses it when it
creates the first administrator in an empty database. Once the database exists, changing
the Secret does not change the password stored in Portainer.

### Run guarded bootstrap

After the suspended source and encrypted Secret are merged and reconciled, an authorized
operator runs from a clean checkout whose guarded source matches `origin/main`:

```bash
PORTAINER_BOOTSTRAP_CONFIRM='bootstrap:portainer' \
  mise exec -- just bootstrap portainer
```

The recipe validates source, reconciles the Flux source and parent application tree,
confirms the live Portainer Kustomization is still suspended, resumes only Portainer,
waits for readiness, and runs `portainer-verify`. If acceptance fails after resume, its
cleanup re-suspends Portainer while preserving created resources, including the PVC.

### Accept the UI safely

Open `https://portainer.lab.supermorphic.com` and confirm:

- the administrator credential works;
- the automatically detected local Kubernetes environment is present;
- the three Talos nodes and expected namespaces and workloads are visible;
- events and permitted pod logs are readable; and
- Secret values are not available.

Do not attempt a production mutation to test whether RBAC denies it. If permissions have
drifted broader, that test could succeed. Use `portainer-verify` as the negative
authorization oracle.

Before making Portainer durably active, run the disruptive persistence test:

```bash
PORTAINER_PERSISTENCE_CONFIRM='recreate:portainer:pod:preserve-pvc' \
  mise exec -- just kube portainer-persistence-test
```

It records the original PVC and pod identities, deletes only the Portainer pod, waits for
a replacement, proves the PVC identity did not change, and confirms the internal UI
recovers. It does not prove administrator login or database semantics; confirm those in
the UI after recreation.

Finally, make `spec.suspend: false` durable in Git and restore the Portainer Gatus
endpoint in the same reviewed change. After merge and Flux reconciliation, rerun
`portainer-verify`.

## Connect Homepage

Homepage uses three read-only Portainer Kubernetes count endpoints for applications,
services, and namespaces. The current route configures local environment ID `1`.

Do not assume every Portainer database uses ID `1`. In Portainer, open **Environments**,
select the local Kubernetes environment, and inspect the numeric environment identifier
in the browser URL. If it differs, update
`kubernetes/apps/monitoring/portainer/app/httproute.yaml` through Git before creating the
Homepage token.

### Understand the token boundary

A Portainer access token has the same Portainer permissions as the user that creates it.
Calling a token “dedicated” separates its lifecycle; it does not narrow its authority.

Portainer CE supports basic non-administrator users and environment assignments, but its
granular read-only Portainer roles are a Business Edition feature. This repository does
not currently validate the creating user for the encrypted Homepage token or prove that
a CE non-administrator identity can call all three Homepage count endpoints. Treat the
current token as sensitive creator-equivalent application authority.

A migration to a dedicated non-administrator Homepage user requires a separate attended
acceptance test of the three count endpoints before the current token is revoked. Do not
broaden Kubernetes RBAC to make that token work: every Portainer user must remain bounded
by the same `portainer-readonly` ServiceAccount.

### Write and deploy the token

Create an access token from the intended Portainer user under **My account → Access
tokens**, copy it once, and store it in the password manager. Then write the encrypted
Homepage Secret from the owning feature worktree:

```bash
export PORTAINER_API_KEY='<Portainer access token>'
export HOMEPAGE_PORTAINER_SECRETS_CONFIRM='write:monitoring:homepage-portainer:sops'

mise exec -- just repo homepage-portainer-secrets

unset PORTAINER_API_KEY HOMEPAGE_PORTAINER_SECRETS_CONFIRM
```

The recipe writes
`kubernetes/apps/monitoring/homepage/app/homepage-portainer.sops.yaml` and stamps that
encrypted blob's revision into the Homepage Deployment. After the reviewed change merges,
Flux updates the Secret and recreates Homepage so the environment variable contains the
new token.

Confirm in Homepage that the Portainer card reports applications, services, and
namespaces. `homepage-verify` proves Homepage readiness and reachability, but it does not
authenticate to Portainer or prove the widget token's privilege.

## Rotate the administrator password

For an existing database:

1. Change the administrator password through Portainer's supported UI or API.
2. Confirm the new password authenticates, then store it in the password manager.
3. Run `portainer-secrets` with the same new value.
4. Validate and review the encrypted diff, then publish it through Git.

The live password changes in step 1. Updating the encrypted bootstrap Secret does not
rotate the existing database. It keeps a future empty-database initialization aligned
with the current administrator credential.

## Recover lost administrator access

Portainer provides an official `portainer/helper-reset-password` process that writes a
new administrator password into the preserved database. On Kubernetes, that process must
stop the normal Portainer writer and mount the same PVC in a temporary helper Pod.

This repository does not currently provide a guarded password-reset recipe. Treat the
missing workflow as an operator recovery boundary:

1. Preserve the healthy `portainer` PVC and confirm its Longhorn state.
2. Plan the exact stop, helper-Pod, cleanup, and resume sequence so Flux and Helm drift
   correction cannot restart Portainer while the helper owns the RWO claim.
3. Use Portainer's supported reset helper; do not edit `portainer.db` manually.
4. Remove the exact temporary helper resource and restore normal Git/Flux reconciliation.
5. Confirm administrator login and rerun `portainer-verify`.
6. Update the password manager and regenerate the encrypted bootstrap Secret with the
   recovered password.

Do not copy a generic upstream `kubectl scale` sequence directly into production. Flux
owns the Deployment and can reverse an uncoordinated manual scale operation. Creating a
repository-guarded reset workflow would be a separate reviewed implementation task.

## Recover the Portainer database

Portainer uses one retained 5 GiB Longhorn `ReadWriteOnce` PVC and a single `Recreate`
Deployment. The volume participates in Longhorn's built-in `default` recurring-job group,
which currently creates daily snapshots and daily off-cluster backups with seven copies
retained.

Use this priority order:

```text
healthy retained portainer PVC
  → keep and reconcile it

lost or unusable PVC
  → select a verified Longhorn backup
  → restore to a new claim
  → validate the restored database in isolation
  → replace the production claim through an approved recovery change

reconciled Portainer
  → verify login, route, RBAC, persistence, and Homepage
```

Follow [Recover Longhorn and application state](../runbooks/recovery.md#recover-longhorn-and-application-state)
for the storage procedure. Longhorn replication is not a backup, and the presence of a
scheduled backup does not prove that it was recently restored successfully.

Loss of Portainer or its database must not affect workloads managed by Flux. If a restore
cannot recover the database, use the empty-database lifecycle above; do not use Portainer
to reconstruct cluster desired state.

## Implementation reference

- `docs/specs/009-portainer-gitops-observability.md` — durable design and authority
  rationale.
- `kubernetes/apps/monitoring/portainer/app/values.yaml` — pinned Portainer CE image,
  chart values, initial administrator Secret, and retained storage.
- `kubernetes/apps/monitoring/portainer/app/rbac.yaml` — exact Kubernetes permissions.
- `kubernetes/apps/monitoring/portainer/app/ciliumnetworkpolicy.yaml` — allowed network
  paths.
- `kubernetes/apps/monitoring/portainer/app/httproute.yaml` — internal route, Homepage
  discovery, widget type, and environment ID.
- `scripts/validate/portainer.sh` and `tests/policy/portainer/` — offline source and RBAC
  validation.
- `scripts/verify/portainer.sh` and `scripts/verify/portainer-rbac.sh` — live acceptance
  and effective RBAC-graph verification.
- `scripts/verify/portainer-persistence.sh` — guarded pod-recreation test.
- [Portainer CLI options](https://docs.portainer.io/advanced/cli) — initial administrator
  password-file semantics.
- [Portainer administrator reset](https://docs.portainer.io/advanced/reset-admin) —
  upstream supported recovery helper.
- [Portainer API access](https://docs.portainer.io/api/access) — per-user access-token
  behavior.
- [Homepage Portainer widget](https://gethomepage.dev/widgets/services/portainer/) —
  environment-ID discovery and widget fields.
