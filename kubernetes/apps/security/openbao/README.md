# OpenBao staged package

This package stages an OpenBao credential broker with three Raft voters. All four Flux
Kustomizations are suspended. The namespace Certificate, server, private route, and
acceptance resources must be activated through the guarded bootstrap workflow after the
operator supplies the encrypted `openbao-seal` Secret and independent recovery destination.
The expected Secret key is `key`, containing exactly 32 random bytes. No Secret value is
stored in this package.

The official [OpenBao chart](https://github.com/openbao/openbao-helm) is pinned to 0.29.6
from `https://openbao.github.io/openbao-helm`; the equivalent official OCI chart digest
was verified as `sha256:98c8fc901e2579ac6da9a805537fcd7a19525ef8e563ae8737dc16fc8f641e3e`.
The server image is `quay.io/openbao/openbao:2.7.0@sha256:71156a1c6623a5fa3f5e61b0c6a8ead0faf0df29a778339188443551995d1315`,
verified against the registry's OCI index digest. The chart's default server version is
2.6.3, so this package sets 2.7.0 explicitly.

Run `mise exec -- just kube openbao-validate` for offline source and rendered-chart checks.
The chart's default readiness probe requires an initialized, unsealed server. The release
only skips the *initial install wait*; upgrades keep their normal readiness handling.
The native disruption budget protects a two-voter quorum, and StatefulSet claim retention
preserves data after scale-down or deletion. An `OnDelete` upgrade needs an attended
standby-first procedure.
