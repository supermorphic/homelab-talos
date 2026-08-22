# Configure and recover Portainer

Portainer CE provides an internal operational view of the Talos Kubernetes cluster at
`https://portainer.lab.supermorphic.com`. It is not a deployment authority. Git and Flux
remain the only desired-state path.

## Authority boundary

The `portainer-readonly` ServiceAccount is the enforcement boundary. It can read
Kubernetes inventory, events, metrics, selected installed CRDs, and pod logs. It cannot
read Secrets, mutate resources, or use pod exec, attach, or port-forward.

Portainer can display controls that imply mutation. The Kubernetes API must return
`Forbidden` when the ServiceAccount uses them. Verify the effective boundary with:

```bash
mise exec -- just kube portainer-verify
```

Do not create Portainer stacks, install Helm applications, or modify Flux-managed
resources through Portainer.

## Create or align the administrator credential

For a new database, create the encrypted bootstrap Secret:

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
`portainer-admin-password.sops.yaml`. Review the ciphertext diff and publish it through
the normal pull-request workflow.

`--admin-password-file` applies only when Portainer creates the first administrator in
an empty database. Updating the Kubernetes Secret does not change a password already
stored on the retained PVC.

For routine rotation:

1. Change the administrator password through Portainer's supported UI or API.
2. Store the new credential in the password manager.
3. Rerun `mise exec -- just repo portainer-secrets` with the new value so recovery of an
   empty database uses the same credential.
4. Commit only the updated ciphertext through a pull request.

If the live password is lost, use Portainer's supported password-reset procedure against
the preserved database. Do not edit the database directly.

## Create the Homepage widget credential

Create a dedicated Portainer access token under **My account → Access tokens**. Store it
in the password manager, then write the independently rotatable Homepage Secret:

```bash
export PORTAINER_API_KEY='<dedicated access token>'
export HOMEPAGE_PORTAINER_SECRETS_CONFIRM='write:monitoring:homepage-portainer:sops'
mise exec -- just repo homepage-portainer-secrets
unset PORTAINER_API_KEY HOMEPAGE_PORTAINER_SECRETS_CONFIRM
```

Commit only the encrypted Secret. The Homepage widget uses Kubernetes environment `1`.

## Verify a fresh database

Portainer detects the in-cluster `portainer-readonly` identity and creates the local
Kubernetes environment on a fresh database. Open the internal URL and confirm:

- the administrator credential authenticates;
- the local Kubernetes environment is present;
- the three Talos nodes and expected namespaces and workloads are visible;
- events and pod logs are readable;
- Secret contents are inaccessible; and
- a harmless attempted resource mutation returns `Forbidden`.

Then run:

```bash
mise exec -- just kube portainer-verify
```

## Recover Portainer

Portainer uses one retained 5 GiB Longhorn `ReadWriteOnce` claim and a `Recreate`
Deployment. The volume participates in the Longhorn `default` recurring-job group for
daily snapshots and backups.

Use this order after database loss or workload recovery:

1. Restore Git and Flux reconciliation and the SOPS decryption identity.
2. Check whether the retained `portainer` PVC is healthy.
3. If it is unavailable, restore the latest verified Longhorn backup into the expected
   claim boundary.
4. Reconcile Portainer with the restored claim.
5. Verify administrator access, read-only Kubernetes authorization, the internal HTTPS
   route, and the Homepage widget.

Losing Portainer must not affect any Flux-managed workload. Standard Docker Agents,
Portainer Edge, external exposure, and Docker-host management are not part of the current
deployment.
