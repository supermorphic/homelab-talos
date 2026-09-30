FROM quay.io/openbao/openbao:2.7.0@sha256:71156a1c6623a5fa3f5e61b0c6a8ead0faf0df29a778339188443551995d1315
LABEL org.opencontainers.image.source="https://github.com/supermorphic/homelab-talos" \
      org.opencontainers.image.description="OpenBao 2.7.0 with projected Kubernetes token refresh" \
      org.opencontainers.image.licenses="MPL-2.0"
COPY --chmod=0555 bao /usr/bin/bao
COPY source.json token-rotation.patch /usr/share/openbao-build/
