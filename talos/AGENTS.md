# Talos Agent Instructions

Binding constraints for all files under `talos/`. Root `AGENTS.md` remains the
floor and this file may only narrow or strengthen it.

- Never hand-edit generated files under root `clusterconfig/`. Change
  `talconfig.yaml` and `patches/`, then regenerate.
- Preserve Talos, Kubernetes, and Cilium compatibility.
- Rendered machine configs contain credentials. Never move them into a trackable
  path.
- Applying a rendered config is a separate guarded operation. Never replace it
  with raw `talosctl apply-config`.
- Never reuse another node's confirmation value.
