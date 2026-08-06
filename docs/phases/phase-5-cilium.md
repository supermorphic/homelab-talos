# Phase 5: Bootstrap Cilium

## Status

- Prepared: 2026-07-19
- Completed: 2026-07-19
- State: Complete
- Chart: Cilium `1.19.6`
- Release: `cilium` in `kube-system`
- Source: `oci://quay.io/cilium/charts/cilium`
- Flux ownership: adopted by Flux in completed Phase 6

Phase 5 installed the cluster CNI from the same app-local values that Flux later
adopted in Phase 6. It did not install Flux, MetalLB, Envoy Gateway, application
workloads, storage controllers, or default-deny network policies.

## Just Interface

Operators do not run raw `helm`, `kubectl`, or `cilium` commands during this
workflow.

| Command | Behavior |
|---|---|
| `just kube cilium-render` | Renders Cilium `1.19.6` to standard output without creating tracked output |
| `just kube cilium-validate` | Checks the Flux package, canonical values, and rendered Helm resources |
| `just kube cilium-status` | Prints read-only Helm, node, workload, and Cilium status |
| `just kube cilium-diagnostics` | Prints read-only Talos diagnostics from all three nodes |
| `just kube cilium-postflight` | Verifies test cleanup, zero Talos diagnostics, three etcd members, and zero etcd alarms |
| `just kube cilium-verify` | Runs the read-only live-state acceptance gate |
| `just kube cilium-connectivity-test` | Runs and removes temporary IPv4 connectivity workloads |
| `just bootstrap cilium` | Runs preflight, requires confirmation, installs or reconciles Helm, and verifies |

Without an activated mise shell, prefix each command with `mise exec --`.

For routine operations, follow the
[`Daily Cluster Health Check`](../../README.md#daily-cluster-health-check) in the
root README. It defines the fast two-command check, healthy expectations,
diagnostic escalation order, and when the full connectivity suite is warranted.

## Ownership Boundary

`kubernetes/apps/kube-system/cilium/app/values.yaml` is the sole values source.
The Phase 5 recipe passed it directly to Helm. The Flux app now generates the
watched `cilium-values` ConfigMap from the same file and the HelmRelease consumes
that ConfigMap through `valuesFrom`.

Phase 5 did not apply the Flux Kustomization, OCIRepository, or HelmRelease
because their CRDs did not exist yet. Phase 6 applied those resources with the
same release name, namespace, chart version, and values; the completed adoption
evidence is in [`phase-6-flux.md`](phase-6-flux.md).

## Guarded Installation

Run local and live preflight first:

```bash
just kube cilium-validate
just kube cilium-status
```

`cilium-status` is expected to fail before the first installation because there
is no release yet. The bootstrap recipe itself requires:

1. Valid tracked Cilium sources and Talos rendered-policy validation.
2. A kubeconfig targeting `https://192.168.90.20:6443`.
3. Exactly `nuc1`, `nuc2`, and `nuc3`.
4. No kube-proxy and no competing CNI.
5. No Flux HelmRelease already claiming Cilium.
6. An absent release or an existing `cilium-1.19.6` Helm release.

For the first installation or a values reconciliation, provide the exact guard:

```bash
CILIUM_BOOTSTRAP_CONFIRM='bootstrap:cilium:1.19.6:kube-system' \
  just bootstrap cilium
```

The Helm operation resets user values to the tracked file, waits for workloads
and jobs, bounds history, cleans newly created upgrade resources on failure, and
rolls back a failed change. If the live release already has the expected chart
and values, the recipe skips the Helm mutation and runs verification.

## Verification Contract

`just kube cilium-verify` is read-only and requires:

- The Helm release is deployed as `cilium-1.19.6` and its user values match Git.
- Exactly three uncordoned nodes report Ready.
- The Cilium DaemonSet has three ready agents.
- Both Cilium operator replicas, Hubble Relay, and CoreDNS are available.
- Hubble UI, Cilium Envoy, and kube-proxy remain absent.
- Cilium status reaches healthy without warnings, Hubble reports `Ok` on every
  agent, and Hubble Relay reports one ready replica with no errors or warnings.
- All three Talos nodes report no diagnostics; etcd still reports three members
  and no alarms.

`just kube cilium-connectivity-test` is the separate state-changing test. It
removes stale Failed pod objects from `kube-system`, creates a temporary
privileged test namespace, exercises DNS, service, policy, pod, node, and
cross-node paths, removes the test resources, and then runs the postflight gate.
It requires
`CILIUM_CONNECTIVITY_CONFIRM='test:cilium-connectivity'`.

Connectivity-test support bundles are written under `/tmp` only when needed and
are never committed.

The connectivity suite disables per-action Hubble flow matching. Cilium's
production `MonitorAggregationLevel=Medium` deliberately coalesces some service
events, which can make the CLI's flow matcher fail even when the recorded flows
show successful forwarded traffic. Hubble health and event availability are
therefore asserted independently instead of weakening production aggregation for
a test harness.

The aggregate `no-unexpected-packet-drops` case is excluded from the automated
gate. The first complete run proved that all functional tests passed but that
this aggregate counter also includes unrelated `192.168.10.0/24` broadcast
frames delivered to the NUC interfaces by the upstream network. Cilium reports
those drops as `VLAN_FILTERED`, which is the expected secure behavior for VLANs
that the cluster has not explicitly allowed. The verifier keeps every
functional packet-delivery and policy test enabled and does not configure
`bpf.vlanBypass`. A VLAN tag must only be allowed after the switch topology and
cluster traffic requirements establish that the tag belongs on these hosts.

## Failure Handling

Use `just kube cilium-status` first. Do not uninstall a functioning CNI or deploy
a second CNI as a workaround. If the initial install fails, Helm returns the
cluster to the pre-CNI state. If a reconciliation fails, Helm preserves the last
successful release. Correct the tracked values, rerun validation, and invoke the
same guarded bootstrap workflow.

After Flux owns the HelmRelease, `just bootstrap cilium` refuses mutation. Cilium
changes then flow through Git and Flux; the bootstrap recipe remains a documented
pre-Flux recovery boundary rather than a second reconciler.

## Acceptance Evidence

| Check | Result |
|---|---|
| Guarded Helm installation | Pass; release revision 1 is deployed as `cilium-1.19.6` |
| Canonical OCI chart render | Pass; digest `sha256:b8d600c542c97dc8652429e12487ecce922d73de9785505457a8f653833e75f9` |
| Canonical values | Pass; live Helm user values exactly match the tracked file |
| Kubernetes nodes | Pass; nuc1, nuc2, and nuc3 are Ready, schedulable, and untainted |
| Cilium agents | Pass; 3 desired, 3 ready, 3 available |
| Cilium operator | Pass; 2 desired, 2 ready, 2 available |
| Hubble | Pass; Relay 1/1, every agent reports `Ok`, no Relay warnings or errors |
| CoreDNS | Pass; available after CNI installation |
| Disabled components | Pass; kube-proxy, Hubble UI, and Cilium Envoy are absent |
| Connectivity suite | Pass; 79 applicable tests and 692 actions succeeded, 53 tests skipped, 0 scenarios skipped |
| Test cleanup | Pass; no `cilium-test*` namespace remains |
| Talos diagnostics | Pass; none on all three nodes |
| Etcd | Pass; three members, one leader, no learners, errors, or alarms |
| Idempotent bootstrap | Pass; matching chart and values skip Helm mutation and proceed to verification |

The first unconfirmed bootstrap rehearsal passed every preflight and refused to
mutate the cluster without the exact confirmation. The confirmed run installed
the release. A later guarded invocation detected the matching release and values
and skipped Helm, proving that the command does not create a second reconciler.

The complete connectivity run initially found only the ambient
`VLAN_FILTERED` aggregate described above; its other 79 applicable tests passed.
After narrowing that aggregate counter, the final run completed with all 79
applicable tests and 692 actions successful. Structured Talos diagnostic output
then confirmed zero resources on all three nodes, and the separate postflight
confirmed cleanup plus healthy three-member etcd with no alarms.
