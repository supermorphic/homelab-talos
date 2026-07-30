# Phase 6: Publish and Bootstrap Flux

## Status

- Prepared: 2026-07-19
- Completed: 2026-07-19
- State: Complete
- Flux CLI and controllers: `2.9.2`
- Git source: `ssh://git@ssh.github.com:443/7yXwscXEzv6phzUnKfrw/homelab-talos`
- Sync path: `kubernetes/flux/clusters/prod`
- Branch and polling: `main`, one minute

## Security Boundaries

Four credentials have separate purposes and lifecycles:

| Credential | Purpose | Stored in cluster | Stored in Git |
|---|---|---:|---:|
| Talos PKI | Talos machine administration | Talos-managed | Encrypted bundle only |
| Repository age identity | Decrypt tracked SOPS documents | Yes, as `flux-system/sops-age` | Public recipient only |
| Temporary GitHub PAT | Create/update Flux bootstrap files and deploy key | No | No |
| Flux SSH deploy key | Read this repository during reconciliation | Yes, as `flux-system/flux-system` | GitHub stores the public key only |

The Flux SSH deploy key is unique to this cluster and read-only. It is not the
Talos key, SOPS key, workstation SSH key, or a key reused by another cluster.
Phase 6 does not install image automation or grant Flux Git write access.

## One-Time GitHub Credential

Create a fine-grained personal access token owned by
`7yXwscXEzv6phzUnKfrw`, limited to the private `homelab-talos` repository. Use
these repository permissions:

- Administration: read and write
- Contents: read and write
- Metadata: read-only (GitHub includes this automatically)

The selected operating policy is no expiration. Keep the token in the password
manager and load it only for bootstrap or deploy-key recovery. The guarded
recipe checks the authenticated account, private repository, and effective
administration/write permissions before calling Flux. It never writes the PAT
to Kubernetes.

## Declarative Layout

```text
kubernetes/
├── flux/clusters/prod/
│   └── apps.yaml
└── apps/
    ├── kustomization.yaml
    ├── flux-system/
    │   ├── kustomization.yaml
    │   └── flux-canary/
    │       ├── ks.yaml
    │       └── app/
    │           ├── kustomization.yaml
    │           └── secret.sops.yaml
    └── kube-system/
        ├── kustomization.yaml
        └── cilium/
            ├── ks.yaml
            └── app/
```

Flux bootstrap adds its generated `flux-system/` controller and synchronization
manifests beside `apps.yaml`. Those generated files are the one intentional
exception to the rule against committing rendered vendor resources because they
are Flux's canonical bootstrap output and upgrade boundary.

## Cilium Adoption Safety

Cilium starts as a suspended child Kustomization. Both the child Kustomization
and HelmRelease carry prune-disable annotations, and the child uses
`deletionPolicy: Orphan`. These controls prevent a bootstrap ordering mistake or
Git deletion from removing the running network.

The adoption recipe verifies the existing chart and values, records every Cilium
pod UID and restart total, resumes only the `cilium` Kustomization, and waits for
its HelmRelease. The initial transfer advances the Helm revision and can perform
a controlled replacement because Helm Controller adds ownership metadata and
regenerates chart-managed certificate material; every resulting workload must be
Ready with zero container restarts. A recovered or repeated adoption must not
advance the revision or replace pods again. The recipe then changes the tracked
source to `suspend: false`; that local diff is an explicit review and commit
boundary.

The cluster Git source uses GitHub's SSH-over-HTTPS endpoint
`ssh.github.com:443`. This retains the repository-scoped read-only deploy key
while avoiding networks that time out outbound SSH port 22.

When migrating an existing bootstrap Secret from port 22, the generated sync URL
can change before its `known_hosts` entry does. The guarded
`just bootstrap flux-ssh-known-hosts` workflow preserves and compares the deploy
public key, obtains the port-443 host entry, verifies GitHub's published ECDSA
fingerprint, updates only the source Secret, and requires the GitRepository to
become Ready.

The permanent encrypted canary depends on Cilium. It cannot become Ready until
the SOPS key exists and Cilium adoption succeeds.

## Execution

Run all commands from the repository root. First merge the reviewed Phase 6
implementation to `origin/main`, then fetch that commit into the current clean
checkout. The checked-out branch may be any feature branch: the guarded workflow
compares the Phase 6 rollout paths with remote `origin/main` instead of requiring
local `HEAD` to equal it. Git review, commit, and push remain explicit
source-control actions; every cluster mutation is encapsulated by a guarded Just
recipe.

```bash
git fetch origin main
git status --short  # must print nothing
```

Validate the published source, pinned Cilium OCI render, and live prerequisites:

```bash
mise exec -- just kube flux-validate
mise exec -- just kube flux-preflight
```

Bootstrap Flux and its read-only deploy key:

```bash
export GITHUB_TOKEN='github_pat_...'
export FLUX_BOOTSTRAP_CONFIRM='bootstrap:flux:prod:7yXwscXEzv6phzUnKfrw/homelab-talos:read-only'
mise exec -- just bootstrap flux
unset FLUX_BOOTSTRAP_CONFIRM GITHUB_TOKEN
```

Load the repository age identity and install its cluster copy:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
export FLUX_SOPS_CONFIRM='create:flux-system:sops-age'
mise exec -- just bootstrap flux-sops
unset FLUX_SOPS_CONFIRM
```

Adopt Cilium:

```bash
export FLUX_CILIUM_ADOPTION_CONFIRM='adopt:cilium:kube-system:flux'
mise exec -- just bootstrap flux-adopt-cilium
unset FLUX_CILIUM_ADOPTION_CONFIRM
```

Review the single intended source change in
`kubernetes/apps/kube-system/cilium/ks.yaml`, commit it, and merge it to `main`. After
Flux observes that commit, run the acceptance gates:

```bash
mise exec -- just kube flux-status
mise exec -- just kube flux-verify
export FLUX_CANARY_CONFIRM='recreate:flux-system:flux-canary'
mise exec -- just kube flux-canary-test
unset FLUX_CANARY_CONFIRM SOPS_AGE_KEY
```

`flux-canary-test` deletes only the labeled noncritical canary Secret, forces its
own Kustomization reconciliation, and requires a new Secret UID and the original
decrypted marker.

## Exit Gate

Phase 6 required live evidence for all of the following:

- Four Flux controllers are healthy at `2.9.2`.
- The GitRepository is Ready on `main` using the matching read-only SSH deploy key.
- `flux-system`, `cluster-apps`, `cilium`, and `flux-canary` are Ready and unsuspended.
- The live SOPS identity derives the repository's committed public recipient.
- The encrypted canary decrypts to marker `ready`.
- Cilium adoption advances the Helm revision, returns every controlled
  replacement to Ready with zero container restarts, and repeated reconciliation
  causes no further rollout.
- The canary recreation test produces a different Secret UID.
- Cilium, Talos diagnostics, and etcd postflight checks still pass.

## Acceptance Evidence

Recorded on 2026-07-19:

| Check | Result |
|---|---|
| Flux installation | Pass; distribution `2.9.2`, all four controllers Ready with one replica and zero restarts |
| Git source | Pass; private `main` source Ready through `ssh.github.com:443` with the repository-scoped read-only deploy key; acceptance revision `3062c618` |
| Git credential boundary | Pass; the cluster source Secret contains only `identity`, `identity.pub`, and `known_hosts`; the temporary bootstrap PAT was not stored in Kubernetes |
| Flux graph | Pass; `flux-system`, `cluster-apps`, `cilium`, and `flux-canary` are Ready and unsuspended at the same source revision |
| SOPS | Pass; the live `sops-age` identity derives committed recipient `age1da2cywfkg9hp6v39jvj9qcmqz4n8w3gm6nqj5vygu7e0zzgnp5psne9wlx` |
| Reconciliation canary | Pass; the encrypted marker decrypts to `ready`, and guarded deletion produced a new Secret UID |
| Cilium source | Pass; OCI tag `1.19.6` is Ready at digest `sha256:b8d600c542c97dc8652429e12487ecce922d73de9785505457a8f653833e75f9` |
| Cilium ownership | Pass; Helm Controller owns Ready revision 2 at `1.19.6+b8d600c542c9` |
| Initial adoption | Pass; the expected one-time ownership/certificate replacement returned all agents, operators, and Hubble Relay to Ready with zero container restarts |
| Adoption idempotence | Pass; the recovered repeat kept Helm revision 2 and caused no additional pod replacement or restart |
| Cilium functional gate | Pass twice; all 79 applicable tests and 692 actions succeeded, 53 feature-gated or unsafe tests were skipped, and 0 scenarios were skipped |
| Test cleanup | Pass; explicit cleanup runs before postflight, terminating namespaces receive a bounded deletion wait, and no `cilium-test*` namespace remains |
| Talos and etcd | Pass; no diagnostics on nuc1, nuc2, or nuc3; three etcd members, no learners, errors, or alarms |

Outbound SSH port 22 timed out from this environment, so the source was migrated
to GitHub's supported SSH-over-HTTPS endpoint. The guarded recovery preserved the
deploy identity and verified GitHub's published ECDSA fingerprint before changing
only the source Secret's host trust. Final Flux verification also passed after
the durable `suspend: false` source was committed and reconciled.
