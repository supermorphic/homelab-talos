# Tautulli agent-rules alignment

## Status

- **Status: Accepted.**
- Date: 2026-08-02

## Context

The accepted
[`Tautulli Plex analytics design`](2026-08-01-tautulli.md) predates the repository's
layered policy, scoped verification, and uncommitted-plan lifecycle. Its application and
monitoring design was subsequently implemented and activated, while its rollout-recipe
assumptions need a precise successor rather than edits to the accepted legacy record.

## Decision

All decisions in the 2026-08-01 Tautulli record remain accepted except where this record
explicitly supersedes them.

### Retained application and monitoring design

- Tautulli remains a config-only, single-replica media application using `Recreate` and a
  retained Longhorn ReadWriteOnce claim. It mounts neither shared media nor the Plex
  config claim.
- Tautulli remains an internal Plex analytics and watch-history service. Web
  authentication is required; there is no direct ntfy producer, shared-media mount,
  history import, or Plex Logs viewer.
- Media alert rules remain isolated in the `media-alerts` Kustomization behind
  kube-prometheus-stack readiness. Generic sustained-down coverage excludes the existing
  qBittorrent VPN alert, while Plex and Tautulli retain explicit missing-probe and
  persistence coverage.
- Source, chart-family, alert, and render invariants are enforced through the layered
  validation model. Tautulli remains part of the media/app-template domain policy.

### Verification and acceptance

`verification.tautulli` is a diagnostic-tier, read-only suite in the canonical test
catalog. Its in-pod Service-DNS request requires diagnostic `pods/exec`; that access
tier does not turn the suite into a mutating rollout.

The verifier's exact `/status` checks prove application liveness and reject login
redirects masquerading as health. Kubernetes HTTP probes accept 3xx responses, so their
green state is not an equivalent oracle. Neither probe nor verifier establishes
functional acceptance: successful Plex authentication, a real playback session recorded
in history, Homepage widget data, and active alert series are separate acceptance facts.

### Rollout eligibility superseding D15

D15's assumption that Helm remediation alone makes Tautulli eligible for removal of its
guarded rollout is replaced by the audit's actual four-criterion rule. An application
qualifies for the one-PR path only when all four hold:

1. It is Helm-managed and has `install.remediation.remediateLastFailure: true`.
2. It has no app-specific safety gate beyond Kustomization readiness.
3. Its Gatus endpoint exercises the function established by its verifier, not merely
   shallow HTTP or TCP liveness.
4. Its verifier runs under the observer or diagnostic credential tier.

The parameterized `bootstrap media-app tautulli` path is retained until Tautulli meets
all four criteria **and** the accepted post-merge acceptance automation exists. A
diagnostic verifier and a `/status` endpoint alone do not satisfy functional criterion 3
or replace the named automation. This supersedes D9 only as a lifecycle rule; the
parameterized implementation remains preferable to copied per-app recipes while it is
retained.

### Documentation lifecycle

The completed tracked implementation plan is removed. Future implementation plans stay
under ignored `/plans/`; durable design changes receive a new decision record. Current
operator procedure remains in [`docs/arr-stack-startup.md`](../arr-stack-startup.md), and
dated rollout evidence remains in [`docs/phases/`](../phases/).

## Review history

The original design's independent review chain is retained under the established
single-date filenames, in evidence order:

1. [Review request](reviews/2026-08-01-tautulli-request.md)
2. [Independent review](reviews/2026-08-01-tautulli-review.md)
3. [Disposition and response](reviews/2026-08-01-tautulli-response.md)

No review artifact is renamed or duplicated by this successor.

## Consequences

The legacy record stays byte-identical apart from its status line. This record carries
the implemented lifecycle changes and prevents diagnostic liveness from being promoted
into functional rollout acceptance.
