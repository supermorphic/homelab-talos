set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

talosconfig := ".talos/config"
kubeconfig := ".kube/config"

# Print read-only status for the established cluster or one node.
status node='all':
    @scripts/cluster/status.sh {{quote(node)}} {{quote(talosconfig)}}

# Verify core established-cluster health without making application health contractual.
verify:
    @scripts/cluster/verify.sh {{quote(kubeconfig)}} {{quote(talosconfig)}}
