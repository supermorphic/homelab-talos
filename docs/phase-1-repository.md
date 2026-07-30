# Phase 1 Repository Evidence

## Status

Phase 1 completed on 2026-07-12. The tool installation, age-key handoff, SOPS
round-trip, repository validation, and secret scans all passed without contacting
or modifying the Talos cluster.

## Repository-Specific SOPS Identity

Public recipient:

```text
age1da2cywfkg9hp6v39jvj9qcmqz4n8w3gm6nqj5vygu7e0zzgnp5psne9wlx
```

The private identity is stored outside Git in the password-manager item
`homelab-talos SOPS age key`. The owner-readable temporary identity used for the
handoff was unlinked after the operator confirmed storage.

## Tool Matrix

| Tool | Version |
|---|---:|
| mise | 2026.7.5 minimum |
| talosctl | 1.13.6 |
| talhelper | 3.1.13 |
| kubectl | 1.35.6 |
| Helm | 4.1.3 |
| Flux CLI | 2.9.1 |
| Cilium CLI | 0.19.5 |
| Kustomize | 5.8.1 |
| SOPS | 3.13.2 |
| age | 1.3.1 |
| yq | 4.52.4 |
| just | 1.56.0 |
| GitHub CLI | 2.96.0 |
| Gitleaks | 8.30.1 |

This table records the Phase 1 tool gate. Flux was deliberately upgraded from
`2.9.1` to `2.9.2` as part of the reviewed Phase 6 bootstrap implementation; the
current authoritative versions are `.mise.toml` and `mise.lock`.

The lockfile records 91 artifacts for seven platform targets. The mise Aqua
registry selected an Intel-only macOS `yq` artifact, so `yq` uses mise's GitHub
backend to select and attest the native ARM64 upstream artifact instead.

## Deliberate Boundaries

- At Phase 1 completion, the manual Talos artifacts remained available but were
  not rebuild inputs. They were retired from the current branch after Phase 5.
- No Talos identity, machine config, or Kubernetes manifest is created in Phase 1.
- Cluster-changing recipes remain disabled until their implementation phases.
- Phase 2 owns the reproducible machine-config render acceptance test.

## Verification

- `mise install --locked` succeeded with the committed cross-platform lockfile.
- Every pinned command reported the expected version; the active `yq` binary is
  native macOS ARM64.
- `just repo verify` passes ignore-boundary, SOPS-policy, Git-history, diff, and
  tracked-file secret checks.
- The new age identity matched the committed recipient and completed an isolated
  SOPS encrypt/decrypt round-trip.
- The then-disabled Talos generation recipe failed at its Phase 2 prerequisite
  without side effects.
- No Talos API, Kubernetes API, disk, bootstrap, or installation command ran.
