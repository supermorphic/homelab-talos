# Spec Review

**Spec:** /Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/docs/decisions/2026-08-01-tautulli.md  
**Reviewer:** OpenAI GPT-5.6-sol (Codex)  
**Verdict:** Not ready — one validation contract makes CI fail deterministically, and several requirements admit materially different implementations.

## Findings

### F1 — Defect
**Where:** §7.2 Validation and §2 Scope  
**Mechanism:** `validation.media-alerts` asserts that no `PrometheusRule` exists under any `kubernetes/apps/media/*/app/` directory other than the new `media-alerts` Kustomization  
**Failure:** the retained `kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml` already violates that assertion, so `media-alerts-validate` exits non-zero and the required `mise exec -- just ci` cannot pass  
**When:** every PR described by the spec while qBittorrent’s existing rule remains in place, as §2 explicitly requires

### F2 — Defect
**Where:** §4.1 Probes and §8.3 acceptance gate 2  
**Mechanism:** three Kubernetes `httpGet` probes are described as asserting HTTP 200 and as failing if authentication redirects `/status` to a login page  
**Failure:** Kubernetes treats every response from 200 through 399 as probe success; a 301/302/307 login redirect therefore leaves readiness, liveness, and startup successful while Gatus’s `[STATUS] == 200` condition fails. The asserted four-surface failure does not occur, and kubelet health can disagree with Gatus.  
**When:** `/status` returns any 3xx response, including the authentication redirect contemplated by the spec

### F3 — Contradiction
**Where:** D5 and §5.2/§7.3  
**D5 says:** one `MediaEndpointDown` rule covers every current and future media endpoint  
**§5.2/§7.3 say:** `qbittorrent-vpn` is explicitly excluded from that rule, and tests must prove the exclusion  
**Why both cannot hold:** `qbittorrent-vpn` is a current `group="Media"` endpoint; the specified negative matcher makes D5’s one rule incapable of covering it, even though a separate existing alert provides overall outage coverage

### F4 — Ambiguity
**Where:** D1, §4 Architecture, and §6.1 Repository footprint  
**Reading 1:** “structural clone of Seerr” includes Seerr’s resource block → Tautulli receives requests of 25m CPU/256Mi memory and a 1Gi memory limit  
**Reading 2:** the architecture and validator requirements are exhaustive → Tautulli receives no resource requests or limits because none are specified  
**Different implementations:** the resulting `values.yaml` files have different scheduling, QoS, and memory-enforcement behavior

### F5 — Ambiguity
**Where:** §8.5 Post-activation gates, §7.4 Verification, and §6.1 Repository footprint  
**Reading 1:** “all rules loaded” and the Gatus-series check are automated acceptance requirements → `scripts/verify/tautulli.sh` or another named guarded verifier queries Prometheus and validates the complete rule list and metric  
**Reading 2:** `tautulli-verify` remains liveness-only as §7.4 says → the operator performs unrecorded Prometheus UI/API inspection and no additional verifier is implemented  
**Different implementations:** one adds tracked executable verification and catalog/recipe coverage; the other adds no repository mechanism for two definition-of-done gates

### F6 — Ambiguity
**Where:** §8.1 PR 1, §8.3 acceptance gate 1, §8.4 PR 2, and §12 Definition of done  
**Reading 1:** the authentication mode is selected before rollout → PR 1 can contain the declared “complete” runbook and the later gate merely confirms that preselected mode  
**Reading 2:** the operator selects the mode during first-run configuration → the runbook must change after PR 1, but the “Exact contents” table for PR 2 omits `docs/arr-stack-startup.md`  
**Different implementations:** the first commits an authentication choice before operational testing; the second changes the documented PR 2 boundary

## Grounding

- **Assumption:** the reviewed artifact matches the request.  
  **Checked:** SHA-256 of the complete 604-line file.  
  **Found:** `104234d67e1022acb79ab3afc37ce345df47f77bca54097bcf31dd274dabcff6`, matching the supplied first 16 characters.

- **Assumption:** qBittorrent’s existing rule conflicts with the proposed validator.  
  **Checked:** [`kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml`](/Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/kubernetes/apps/media/qbittorrent/app/prometheusrule.yaml) and §7.2’s asserted directory-wide invariant.  
  **Found:** the existing file is a `PrometheusRule` under exactly the directory pattern the validator forbids; F1 is confirmed.

- **Assumption:** the rollout-guard count is currently 24 and one new guarded recipe makes 25.  
  **Checked:** occurrences in `.just/bootstrap.just` and `kubernetes/mod.just`, plus `.just/repository.just:1206`.  
  **Found:** 22 + 2 = 24 today, and the repository assertion is `-eq 24`; the proposed single new occurrence correctly requires 25.

- **Assumption:** resource sizing is omitted despite the Seerr-clone decision.  
  **Checked:** [`seerr/app/values.yaml`](/Users/ksiggins/Development/homelab-talos.tautulli-monitoring-addition/kubernetes/apps/media/seerr/app/values.yaml) and all current media `values.yaml` files.  
  **Found:** Seerr specifies 25m CPU/256Mi memory requests and a 1Gi memory limit. Most media siblings specify resources, although qBittorrent is a counterexample to the brief’s statement that every sibling does. The Tautulli spec selects no resource behavior; F4 is confirmed.

- **Assumption:** no existing named verification covers the post-activation media rules or Tautulli Gatus series.  
  **Checked:** `scripts/verify/`, `scripts/lib/`, `kubernetes/mod.just`, and `tests/catalog.yaml`.  
  **Found:** `monitoring-verify` already queries `/api/v1/rules`, but only validates the two Flux rules. No current command checks `MediaEndpointDown`, the media absence/PVC rules, or the Tautulli Gatus series; F5 is confirmed.

- **Assumption:** excluding `qbittorrent-vpn` has observable alert-delivery consequences.  
  **Checked:** the existing qBittorrent rule and Alertmanager configuration.  
  **Found:** `QbittorrentVpnDown` already matches that endpoint. Alertmanager groups by `alertname`, `namespace`, and `severity`, while inhibition requires equal `alertname`; a simultaneous generic warning would neither group with nor be inhibited by the existing critical alert.

- **Assumption:** Kubernetes probes enforce exact HTTP 200.  
  **Checked:** the official [Kubernetes probe semantics](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes).  
  **Found:** HTTP status codes from 200 through 399 are successful; F2 is confirmed.

- **Assumption:** `/status` authentication behavior on `ghcr.io/home-operations/tautulli:2.17.2`.  
  **Checked:** current upstream Tautulli `webserve.py` and `webstart.py`.  
  **Found:** current upstream source exposes `/status` without `requireAuth()` for an argument-free request and disables basic auth for that path. Exact behavior of the pinned `2.17.2` image remains **UNVERIFIED**.

- **Assumption:** live Gatus metrics carry both `group` and `name` labels.  
  **Checked:** repository Gatus endpoint configuration and existing Prometheus rules.  
  **Found:** YAML consistently defines both fields and existing rules match them, but the live exported series was not queried; exact runtime labels remain **UNVERIFIED**.
