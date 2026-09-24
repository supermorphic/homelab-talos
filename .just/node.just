set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

talosconfig := ".talos/config"
kubeconfig := ".kube/config"

# Resize the Longhorn Talos user volume on one established node.
resize-longhorn node:
    @scripts/node/resize-longhorn.sh {{quote(node)}} {{quote(kubeconfig)}} {{quote(talosconfig)}}
