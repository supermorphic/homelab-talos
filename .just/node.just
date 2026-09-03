set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := ".."

talosconfig := ".talos/config"
kubeconfig := ".kube/config"

# Check whether one established node can safely enter planned maintenance.
maintenance-check node:
    @scripts/node/lifecycle.sh maintenance-check {{quote(node)}} {{quote(kubeconfig)}} {{quote(talosconfig)}}

# Cordon, drain, evacuate Longhorn replicas, and shut down one node.
maintenance-enter node:
    @scripts/node/lifecycle.sh maintenance-enter {{quote(node)}} {{quote(kubeconfig)}} {{quote(talosconfig)}}

# Accept a returned contained node, restore Longhorn state, and uncordon it.
maintenance-exit node:
    @scripts/node/lifecycle.sh maintenance-exit {{quote(node)}} {{quote(kubeconfig)}} {{quote(talosconfig)}}

# Gracefully drain and reboot one established node without replica evacuation.
reboot node:
    @scripts/node/lifecycle.sh reboot {{quote(node)}} {{quote(kubeconfig)}} {{quote(talosconfig)}}

# Resize the Longhorn Talos user volume on one established node.
resize-longhorn node:
    @scripts/node/resize-longhorn.sh {{quote(node)}} {{quote(kubeconfig)}} {{quote(talosconfig)}}
