# Testing layers

The cluster is validated in layers, each with a distinct job. They **supplement** each
other — nothing here replaces the production monitoring.

| Layer | What | How | Cadence |
|---|---|---|---|
| **Continuous** | Live service health + alerting | Gatus + the qBittorrent/etc. `PrometheusRule`s | Always-on, in-cluster |
| **Routine** | Read-only platform + app readiness assertions | Chainsaw **smoke** (`just test smoke platform [<subsystem>]`, `just test smoke media <app>`) | Operator- or **external-cron**-driven |
| **Controlled failure** | Disruption + recovery scenarios (VPN stop, pod recreation, node reschedule/reboot) with recorded evidence | Chainsaw **resilience** (`just test resilience <target>`, chaos-token gated) | Operator, on demand |
| **Deep validation** | Upstream Kubernetes conformance | **Sonobuoy** (`just kube conformance`) | Operator, on demand |

Offline correctness (source/render validation, Conftest policy, ShellCheck, probe unit
tests) is the `just ci` contract and gates every PR; it needs no cluster.

## Conformance (Sonobuoy) — on demand, ephemeral, never scheduled

Sonobuoy is **not** deployed or scheduled as a standing cluster workload. It is run on
demand and torn down afterward (`run → retrieve → delete`), leaving nothing behind.

```
mise exec -- just kube conformance                 # MODE=quick (default)
MODE=certified mise exec -- just kube conformance   # full certified suite
```

- **`quick` (default, ~5–10 min)** — Sonobuoy's quick E2E subset (a couple of sanity
  tests). A pass is a **validation-subset pass**, *not* upstream Kubernetes conformance
  evidence. Run it after Kubernetes/Talos/Cilium or other meaningful infrastructure
  changes, and occasionally as a manual health check.
- **`certified` (~1.5–2 h)** — the full `certified-conformance` suite. A pass **is**
  upstream Kubernetes conformance evidence. Run it before/after a major Kubernetes upgrade,
  after substantial networking/storage/platform architecture changes, or when you
  specifically need conformance evidence.

The recipe preflight-checks the cluster is reachable and no prior Sonobuoy run is still
installed, preserves results under `.test-results/<ts>-…-conformance/` (retrieved **before**
teardown, even on failure/interruption), prints the `sonobuoy results` summary, and always
deletes the Sonobuoy namespace.

## Intentionally out of scope

Per the framework's foundation plan, the following are **not** built here: a standing
Sonobuoy/conformance install, any chaos-controller install, and **scheduled in-cluster
tests**. "Periodic" running of the routine suites is done by the operator or an **external**
scheduler, not by an in-cluster cron.
