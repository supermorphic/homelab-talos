# Portainer GitOps Observability

## Intent and authority

Portainer supplies internal Kubernetes inventory, events, metrics, and pod logs. Git
remains desired-state authority and Flux reconciles it. Portainer cannot become a second
deployment interface. [Application source](../../kubernetes/apps/monitoring/portainer/)
owns the chart, listener pruning, RBAC, retained database, and network policy.

`localMgmt: false` suppresses chart-generated cluster administration but does not disable
local-environment discovery. The post-renderer assigns the repository-owned read-only
ServiceAccount because the chart omits that assignment in this mode. Kubernetes RBAC,
rather than displayed UI controls, enforces bounded inventory/log reads and denies Secret
bodies, mutation, exec/attach/port-forward, bind/escalate/impersonate, and wildcards.
Internal route and DNS/API-only network paths limit the server's reachability.

Before chart upgrades, revalidate local management suppression, explicit ServiceAccount,
pruned Edge/HTTPS Service ports, and trusted-origin semantics. Version-specific hostname
versus full-URL origin requirements belong in source. A render cannot silently restore
administration or additional listeners.

## Database and credentials

The bootstrap administrator Secret initializes only an empty database. Once state exists,
the database owns live login credentials, tokens, users, and UI state. To rotate a known
password, change it through the supported UI/API, verify login, update the password manager,
then regenerate matching bootstrap ciphertext via `mise exec -- just repo portainer-secrets`.
Changing that Secret alone does not rotate an existing administrator.

Homepage's separate token has its creator's application permissions; an independent
lifecycle is not proof of least privilege. A narrower CE user requires attended acceptance
of all required widget calls before revoking the old token. Do not widen Kubernetes RBAC
to make an application token work. Inspect the local environment's actual numeric ID in
the UI and align the Homepage route configuration through Git rather than assuming a
new database retains the original ID.

## Empty database and acceptance

Stage source suspension and the encrypted bootstrap credential through reviewed Git;
remove the active Gatus probe during deliberate suspension. Use the guarded
`mise exec -- just bootstrap portainer` workflow from the authorized clean checkout matching
deployed main. Its help/source owns exact guards. On failure it preserves resources and
re-suspends reconciliation.

Require administrator login, automatic local-environment discovery without an Agent or
imported kubeconfig, permitted inventory/log reads, and no Secret-body visibility.
Use `portainer-verify` to check the complete authorization graph; do not try a production
mutation as a denial test because drift could let it succeed. Before activation, run the
registered persistence test and then recheck login and usable UI state. That test proves
same-claim pod replacement, not backup restore or full database semantics. Make activation
and restored Gatus monitoring durable through Git, then rerun the verifier.

## Recover lost administrator access

Preserve the healthy PVC. Portainer's supported reset helper must exclusively mount the
same database while the normal writer is stopped. There is no repository-guarded password
reset workflow, so this remains an operator recovery boundary:

1. Confirm Longhorn state and review the exact Flux/Helm stop, helper creation, cleanup,
   and resume sequence. Reconciliation must not recreate the writer during helper access.
2. Use the supported `portainer/helper-reset-password` process on that preserved claim;
   never edit `portainer.db` manually or replace it merely to recover login.
3. Remove the exact helper resource, restore normal reconciliation, and require login
   plus `portainer-verify`.
4. Update password-manager custody and matching encrypted bootstrap state.

A generic upstream scale command is insufficient under Flux ownership. Implement and
review a guarded workflow before automating this sequence.

## Recover database state

Retain a healthy claim. For lost/unusable state, choose a verified Longhorn backup,
restore to a new claim, validate the database in isolation, then replace production
through an approved recovery change. [Platform recovery](010-talos-flux-platform.md)
owns storage prerequisites. Replication and scheduled backups do not prove restore
acceptance. Require login, internal route, RBAC, persisted local environment, and actual
Homepage data after recovery. If no usable database remains, use the empty-state lifecycle;
Portainer never reconstructs Flux desired state.

Standard/Edge Agents and Docker-host management remain outside this design. Docker socket
access is host authority, and CE has no proven read-only Docker role. Any later integration
needs separate authorization, bounded network paths, authenticated Agent acceptance, and
continued external desired-state ownership. Database encryption requires its own key and
recovery lifecycle rather than an unreviewed toggle.
