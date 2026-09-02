#!/usr/bin/env bash

n8n_single_pod_identity() {
  jq -r '
    .items |
    if length == 1 then
      [.[0].metadata.name // "", .[0].metadata.uid // "", .[0].spec.nodeName // ""] |
      @tsv
    else
      ""
    end
  '
}

n8n_single_ready_node() {
  jq -r '
    [.items[] | select(
      ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "") == "True"
    ) | .spec.nodeName] |
    if length == 1 then .[0] else "" end
  '
}
