# Testing layers

The cluster is validated in layers, each with a distinct job. They **supplement** each
other — nothing here replaces the production monitoring.

| Layer | What | How | Cadence |
|---|---|---|---|
| **Continuous** | Live service health + alerting | Gatus + the qBittorrent/etc. `PrometheusRule`s | Always-on, in-cluster |
| **Routine** | Read-only platform + app readiness assertions | Chainsaw **smoke** (`just test smoke platform [<subsystem>]`, `just test smoke media <app>`) | Operator- or **external-cron**-driven |
| **Controlled failure** | Disruption + recovery scenarios (VPN stop, pod recreation, node reschedule/reboot) with recorded evidence | Catalog-dispatched **resilience** (`just test resilience <target>`, Chainsaw for Kubernetes lifecycles and a direct orchestrator for Talos reboot) | Operator, on demand |
| **Deep validation** | Upstream Kubernetes conformance | **Sonobuoy** (`just kube conformance`) | Operator, on demand |

Offline correctness (source/render validation, Conftest policy, ShellCheck, probe unit
tests) is the `just ci` contract and gates every PR; it needs no cluster.

The [repository command lifecycle](repository-command-lifecycle.md) defines the semantic
boundary: verification is observational toward its target, while deliberate temporary
mutation belongs to a controlled test with explicit ownership, evidence, and cleanup.

## Conformance (Sonobuoy) — on demand, ephemeral, never scheduled

Sonobuoy is **not** deployed or scheduled as a standing cluster workload. It is run on
demand and torn down afterward (`run → retrieve → delete`), leaving nothing behind.

```
mise exec -- just kube conformance                 # MODE=quick (default)
MODE=certified mise exec -- just kube conformance   # full certified suite
mise exec -- just kube conformance-status          # read-only active-run diagnosis
```

- **`quick` (default, ~5–10 min)** — Sonobuoy's quick E2E subset (a couple of sanity
  tests). A pass is a **validation-subset pass**, *not* upstream Kubernetes conformance
  evidence. Run it after Kubernetes/Talos/Cilium or other meaningful infrastructure
  changes, and occasionally as a manual health check.
- **`certified` (~1.5–2 h)** — the full `certified-conformance` suite. A pass **is**
  upstream Kubernetes conformance evidence. Run it before/after a major Kubernetes upgrade,
  after substantial networking/storage/platform architecture changes, or when you
  specifically need conformance evidence.

The recipe validates the registered mode, acquires the shared state-changing
test Lease, checks that no prior Sonobuoy run is installed, and always attempts
teardown. Its canonical `.test-results/<run-id>/` retains publish-safe summaries
and merged, non-vacuous E2E JUnit; cleanup or harness problems are recorded as
JUnit errors and accepted by `just test result-validate`.

Sonobuoy's raw archive includes broad cluster resources and pod logs that may
contain secret-like or sensitive values. It is therefore never placed in the
canonical result or uploaded to Allure. Successful runs discard it after safe
JUnit extraction. Failed or broken runs retain it locally at
`.test-private-results/<run-id>/sonobuoy/sonobuoy-results.tar.gz`; that location
is gitignored and must be treated as private diagnostic material.

Both modes explicitly run only Sonobuoy's `e2e` plugin. The default
`systemd-logs` plugin requires `journalctl`, which Talos does not provide, and can
otherwise leave its result worker waiting indefinitely. Quick runs have a
15-minute aggregator timeout and 20-minute CLI wait; certified runs have a
3-hour aggregator timeout and 190-minute CLI wait.

## Intentionally out of scope

Per the framework's foundation plan, the following are **not** built here: a standing
Sonobuoy/conformance install, any chaos-controller install, and **scheduled in-cluster
tests**. "Periodic" running of the routine suites is done by the operator or an **external**
scheduler, not by an in-cluster cron.
