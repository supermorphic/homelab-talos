# cert-manager

cert-manager `v1.21.0` owns ACME DNS-01 issuance for the internal wildcard.
`cert-manager` installs CRDs and controllers; `cert-manager-config` supplies the
encrypted Cloudflare credential and networking namespace; `wildcard-certificate`
creates the production issuer and wildcard certificate. A permanent staging issuer
and certificate are intentionally absent. Use a temporary staging resource only for
a deliberate future issuance experiment.

The Cloudflare token is scoped to Zone Read and DNS Edit for only
`supermorphic.com`. Its tracked Secret is SOPS encrypted. Use the guarded foundation
Just workflows in the [root README](../../../../README.md); do not apply issuers or
certificates directly. The
[certificate specification](../../../../docs/specs/016-cert-manager-staging-retirement.md)
records the current production boundary.
