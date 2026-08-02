# Agent cluster access

Agent worktrees start without cluster credentials. When live diagnosis is necessary,
the agent stops and asks the operator to run the location-aware installer from that
worktree:

```bash
mise exec -- just talos kubeconfig
```

In a linked worktree this writes a 30-day Kubernetes credential pair to `.kube/config`
and a 90-day Talos `os:reader` credential to `.talos/config`. The kubeconfig's current
context is `homelab-observer`; `homelab-diagnostic` is present for the named verifiers
that need `exec` or `port-forward`. In the main clone the same recipe retains its admin
kubeconfig behavior. Credential minting remains operator-run because it reads the main
clone's admin credentials.

Do not copy, symlink, or commit either credential file. Re-run the installer from the
worktree when a scoped credential expires. Keep SOPS key material out of agent sessions.

## Access tiers

- **observer** — Kubernetes `view`, pod logs, metrics, and explicit reads of the Flux,
  Cilium, Gatus, Tailscale, Longhorn, and Trivy resources used here. It cannot read
  Secret bodies, use interactive pod subresources, or mutate resources.
- **diagnostic** — observer plus `pods/exec` and `pods/portforward`. This is reduced
  privilege, not read-only: an exec command can change container state and can inspect
  data already present in a process. Use it only through the named verifier paths.
- **operator** — the main clone's admin credential. A verifier stays here when its
  functional oracle requires data that scoped credentials deliberately cannot read.
- **Talos reader** — `os:reader`, used only for read-only node inspection.

The diagnostic verifiers select `homelab-diagnostic` only when that named context is
present. Therefore an operator admin kubeconfig without renamed contexts can continue to
run the same recipes using its current context.

## Verifier matrix

| Verifier | Tier | Reason |
|---|---|---|
| `agent-access` | diagnostic | Exercises both named Kubernetes contexts and the Talos reader boundary. |
| `metrics-server` | observer | Reads rollout, APIService, and metrics state. |
| `cilium` | observer | Reads Cilium and Kubernetes health. |
| `flux` | observer | Reads controller, source, Kustomization, HelmRelease, and reconciliation state. |
| `foundation` | observer | Reads foundation controllers and routes. |
| `storage` | observer | Reads storage health and resources. |
| `csi-driver-smb` | observer | Reads driver rollout and storage state. |
| `media-storage` | observer | Reads the media storage contract. |
| `plex` | observer | Reads rollout, route, and application health. |
| `intel-gpu-plugin` | observer | Reads plugin rollout and advertised resources. |
| `qbittorrent` | observer | Reads rollout, route, and functional endpoint state. |
| `prowlarr` | observer | Reads rollout, route, and application state. |
| `sonarr` | observer | Reads rollout, route, and application state. |
| `radarr` | observer | Reads rollout, route, and application state. |
| `lidarr` | observer | Reads rollout, route, and application state. |
| `seerr` | observer | Reads rollout, route, and application state. |
| `flaresolverr` | diagnostic | Port-forwards its in-cluster-only Service to preserve the ready-JSON oracle. |
| `qbit-manage` | observer | Reads controller and job state. |
| `monitoring` | operator | Its retained routing oracle reads Alertmanager's generated configuration Secret; replacing that full oracle is outside this change. |
| `gatus` | observer | Reads Gatus endpoint and rollout state. |
| `portainer` | observer | Reads workload, PVC, route, network policy, and effective RBAC state. |
| `test-reports` | observer | Reads report service and storage state. |
| `homepage` | diagnostic | Executes a read-only file-existence check in the running Homepage pod. |
| `trivy` | observer | Reads operator and report CRDs. |
| `tailscale-operator` | observer | Reads operator and ProxyGroup state. |
| `tailscale-subnet-router` | observer | Reads Connector, ProxyGroup, route, and workload state. |
| `ntfy` | diagnostic | Executes ntfy's runtime ACL query and uses provisioned process credentials for authenticated ACL checks without Secret API reads. |
| `alertmanager-ntfy` | observer | Reads rollout state and Alertmanager's loaded configuration through `/api/v2/status`. |

## Verification workflow

The access application is initially suspended. After it has landed on `main`, the
operator follows the guarded bootstrap output to deploy it, then mints credentials in a
worktree. No live check in this runbook should be attempted before those steps.

Prove the authorization matrix without mutating the cluster:

```bash
mise exec -- just kube agent-access-verify
```

The gate requires observer workload/CRD/log reads to succeed; observer Secret, exec,
port-forward, create, patch, and delete requests to be denied; diagnostic exec and
port-forward requests to succeed while Secret and Flux mutations remain denied; and
Talos version and service inspection to succeed with the reader credential.

Plan the scoped live campaign, review its exact membership and confirmation, then run
only with the confirmation it prints:

```bash
mise exec -- just test campaign-plan scoped-verification
```

`scoped-verification` contains only observer and diagnostic suites. The complete
`verification` campaign also contains operator-only suites and must run with operator
credentials. Neither live campaign is part of `executions.ci`; CI remains secret-free
and cluster-independent.
