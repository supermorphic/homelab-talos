# Portainer Phase 1 Operations

Portainer CE provides an internal operational view of the Talos Kubernetes
cluster at `https://portainer.lab.supermorphic.com`. It is not a deployment
authority: Git and Flux remain the only desired-state path.

Phase 1 intentionally excludes Docker/Pi Agents, `AGENT_SECRET`, Portainer
stacks, database encryption, and any external exposure.

## Security Boundary

The `portainer-readonly` ServiceAccount is the enforcement boundary. Its
ClusterRole permits Kubernetes inventory, events, metrics, selected installed
CRDs, and pod logs. It does not permit:

- reading Secrets;
- creating, updating, patching, or deleting resources; or
- pod exec, attach, or port-forward.

Portainer may display controls that imply mutation, but the Kubernetes API must
return `Forbidden`. Verify the effective permissions with:

```bash
mise exec -- just kube portainer-verify
```

A CiliumNetworkPolicy permits only:

- Envoy Gateway to Portainer TCP 9000;
- node health probes to the pod's TCP 9443;
- Portainer to the Kubernetes API; and
- Portainer to CoreDNS.

The chart's Edge port 8000 and HTTPS Service port 9443 are removed by a
post-renderer. Only the internal Gateway routes to the Service on port 9000.

## Initial Administrator Secret

The operator creates the encrypted bootstrap Secret before the staging PR:

```bash
printf 'Initial Portainer administrator password: '
read -rs PORTAINER_ADMIN_PASSWORD
printf '\n'
export PORTAINER_ADMIN_PASSWORD
export PORTAINER_SECRETS_CONFIRM='write:monitoring:portainer-admin:sops'

mise exec -- just repo portainer-secrets

unset PORTAINER_ADMIN_PASSWORD PORTAINER_SECRETS_CONFIRM
```

The recipe requires the repository SOPS age identity and writes only
`portainer-admin-password.sops.yaml`. Review the ciphertext diff and run
`mise exec -- just ci` before committing.

Portainer's `--admin-password-file` applies only while creating the first
administrator in a new database. Updating the Kubernetes Secret does **not**
change an administrator password already stored in the Portainer PVC.

For routine rotation:

1. Change the administrator password through Portainer's supported UI/API
   workflow.
2. Store the new credential in the password manager.
3. Re-run `just repo portainer-secrets` with the new value so disaster recovery
   initializes the same credential.
4. Commit the ciphertext change through a PR.

If the live password is lost, use Portainer's supported password-reset
procedure against the preserved database. Do not edit the database directly.

## Staged Rollout

The first PR keeps `kubernetes/apps/monitoring/portainer/ks.yaml` at
`suspend: true`. This matches the repository's established application rollout
contract: none of the application resources reconcile until the guarded
bootstrap resumes the complete unit atomically.

After the staging PR is merged to `main`:

```bash
export PORTAINER_BOOTSTRAP_CONFIRM='bootstrap:portainer'
mise exec -- just bootstrap portainer
unset PORTAINER_BOOTSTRAP_CONFIRM
```

The recipe:

1. proves its rollout source paths match deployed `origin/main`;
2. runs static chart and RBAC validation;
3. confirms the live Kustomization is suspended;
4. resumes and reconciles it;
5. runs live acceptance; and
6. re-suspends it on failure while preserving created resources.

After successful acceptance, prove the database survives pod recreation:

```bash
export PORTAINER_PERSISTENCE_CONFIRM='recreate:portainer:pod:preserve-pvc'
mise exec -- just kube portainer-persistence-test
unset PORTAINER_PERSISTENCE_CONFIRM
```

After live acceptance and the persistence test, the activation PR changes the
Portainer Kustomization to `suspend: false` and adds the Portainer Gatus endpoint
plus Prometheus alerts for sustained endpoint failure, missing probe telemetry,
and an absent or unbound database PVC. Do not add the probe while the app is
staged absent.

The activation also enables Homepage's Kubernetes-mode Portainer widget for
environment `1`. Create a dedicated access token in Portainer under **My
account → Access tokens**, store it in the password manager, and generate the
split Homepage Secret before committing:

```bash
export PORTAINER_API_KEY='<dedicated access token>'
export HOMEPAGE_PORTAINER_SECRETS_CONFIRM='write:monitoring:homepage-portainer:sops'
mise exec -- just repo homepage-portainer-secrets
unset PORTAINER_API_KEY HOMEPAGE_PORTAINER_SECRETS_CONFIRM
```

The widget deliberately omits `fields`, so Homepage uses its default Kubernetes
summary fields.

## First-Run Acceptance

No environment onboarding is required for the Talos cluster. Although
`localMgmt: false` prevents the official chart from creating a cluster-admin
binding, the post-rendered Deployment uses the `portainer-readonly`
ServiceAccount. Portainer detects that in-cluster identity and automatically
creates the local Kubernetes environment on a fresh database; the retained
database preserves it across later starts.

Open the internal URL and confirm:

- the initial administrator credential authenticates;
- the automatically discovered local Kubernetes environment is present;
- all three Talos nodes and expected namespaces/workloads are visible;
- events and pod logs are readable;
- Secret contents are inaccessible; and
- a harmless attempted resource mutation returns `Forbidden`.

Do not create Portainer stacks, install Helm applications, or modify
Flux-managed resources through Portainer.

## Storage, Backup, and Recovery

Portainer uses one 5 Gi Longhorn `ReadWriteOnce` PVC and a `Recreate`
Deployment. The PVC has `helm.sh/resource-policy: keep`, so Helm uninstall
leaves it behind instead of triggering Longhorn's delete reclaim path.

The volume participates in Longhorn's existing `default` recurring-job group:
daily snapshots and daily backups to the configured NAS target. Confirm the
volume receives those jobs and that a backup completes after rollout.

Recovery order:

1. Restore Git/Flux reconciliation and the SOPS decryption identity.
2. Confirm whether the retained `portainer` PVC is healthy.
3. If it is unavailable, restore the latest verified Longhorn backup.
4. Reconcile Portainer with the restored claim.
5. Verify administrator access, read-only Kubernetes authorization, and the
   internal HTTPS route.

Losing Portainer must not affect any Flux-managed workload.

## Deferred Phase 2: Standard LAN Agents

Pi/Docker integration is separate work and is not a Phase 1 acceptance gate.
When explicitly started, Phase 2 will:

- deploy matching-version standard Portainer Agents through the Pi repository;
- store a shared `AGENT_SECRET` independently under each repository's SOPS key;
- discover actual Pod-to-LAN source addresses before applying Pi firewall
  allowlists for TCP 9001;
- amend the Cilium egress policy only for approved Agent addresses;
- test incorrect-secret rejection against a disposable Agent; and
- register the approved Docker environments in Portainer.

With `AGENT_SECRET`, Agents do not rely on first-claim ownership: matching the
shared secret authorizes the connection. The `/ping` endpoint proves network
reachability only, not successful secret authentication.

Portainer CE does not provide a Docker read-only role. A standard Agent mounting
the Docker socket has host-level Docker authority, so the later integration
must retain the procedural rule that Ansible/Compose—not Portainer—owns Docker
desired state.
