#!/usr/bin/env bash

# Normalize the Tailscale Connector status route string for exact comparisons.
# In operator v1.98.9, `.status.subnetRoutes` is a comma-separated string produced
# by Routes.Stringify(), unlike `.spec.subnetRouter.advertiseRoutes` (an array).
tailscale_connector_status_routes() {
  yq -p=json -r '
    .status.subnetRoutes // "" |
    split(",") |
    sort |
    join(",")
  '
}
