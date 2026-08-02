#!/usr/bin/env bats

# Catches a production break where the app Kustomization reconciles a benchmark
# Job automatically or loses the deliberately background-only scheduling class.
@test "Flux renders inert resources but no Job" {
  run kustomize build kubernetes/apps/media/encode-benchmark/app
  [ "$status" -eq 0 ]
  [ "$(yq -r 'select(.kind == "Job") | .metadata.name' <<<"$output")" = "" ]
  [ "$(yq -r 'select(.kind == "PriorityClass") | .value' <<<"$output")" = "-10" ]
}

# Catches a production break where the render-only Job can traverse the shared
# PVC outside the movies subtree or can mutate the movie library.
@test "template cannot see TV or downloads and movies are read-only" {
  template=kubernetes/apps/media/encode-benchmark/templates/job.yaml
  [ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "media") | .persistentVolumeClaim.claimName' "$template")" = media-data ]
  [ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .readOnly' "$template")" = true ]
  [ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .mountPath' "$template")" = /media ]
  [ "$(yq -r '.spec.template.spec.containers[0].volumeMounts[] | select(.name == "media") | .subPath' "$template")" = media/movies ]
  ! rg -n '/data|media/tv|downloads' "$template"
}
