# Recovery verification contract

`just kube recovery-verify /absolute/private/request.json` is the read-only
verification boundary used by the Talos node lifecycle controller. The command
accepts preparation, baseline, and recovery requests. It does not acquire a
Lease, change a Node, start a connectivity workload, publish a report, or invoke
lifecycle code.

Before invoking the verifier, prepare the five exact chart archives from the
validated source checkout:

```text
mise exec -- just kube recovery-cache-prepare /absolute/validated/source/.cache/recovery-helm
```

This separate workflow downloads Cilium, cert-manager, MetalLB, Envoy Gateway,
and external-dns at the versions selected by that checkout. It writes one
archive per chart and `manifest.json`, which binds each chart name, version, and
SHA-256 digest to the checkout commit. The destination must not already exist.

Set `RECOVERY_HELM_CACHE` to the absolute prepared cache path when invoking the
verifier. The cache location is part of the trusted process environment and is
not a request field:

```text
RECOVERY_HELM_CACHE=/absolute/private/source/.cache/recovery-helm \
  mise exec -- just kube recovery-verify /absolute/private/request.json
```

The verifier rejects a missing cache, symlinks, a different source revision,
unexpected entries, changed digests, and chart archives whose embedded name or
version differs from the selected source. It completes all cache checks before
the first target API call. Verifier `prepare`, `baseline`, and `recovery` modes
use only local archives and do not fall back to network chart resolution.

The caller supplies one JSON object with these exact keys:

- `schemaVersion`: integer `1`
- `requestId`: UUID used to bind the response
- `mode`: `prepare`, `baseline`, or `recovery`
- `node`: one node in the desired three-node control-plane map
- `sourceRevision`: full commit ID of the selected verifier checkout
- `apiServer`, `nodes`, and `talosEndpoints`: values that exactly match
  `talos/talconfig.yaml` in that checkout
- `credentials`: absolute `kubeconfig` and `talosconfig` paths plus explicit
  `kubeContext` and `talosContext` names
- `expectedContainment`: `null` for preparation and baseline; for recovery,
  the selected node and exact schema-1 annotation string
- `timeoutSeconds`: integer from 1 through 3600

Preparation validates source and dependencies without target API calls. Baseline
requires all expected nodes to be Ready and schedulable with no lifecycle
annotation. Recovery requires every expected node to be Ready and permits only
the selected node to be cordoned with the exact requested annotation. The
annotation key is `homelab.supermorphic.com/node-lifecycle`.

On success, stdout contains exactly one JSON object. It binds `schemaVersion`,
`requestId`, `mode`, `node`, `sourceRevision`, `kubeContext`, and `talosContext`
to the request. Its `checks` object contains only `source`, `cilium`, and
`foundation`. Preparation reports `source: passed` and both live stages as
`not-run`; baseline and recovery report all three stages as `passed`. A nonzero
child status, malformed observation, timeout, or cleanup failure makes the
command fail without a success response.
