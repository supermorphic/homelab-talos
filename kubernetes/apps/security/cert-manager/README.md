# cert-manager

cert-manager `v1.21.0` owns ACME DNS-01 issuance for the internal wildcard.
`cert-manager` installs CRDs and controllers; `cert-manager-config` supplies the
encrypted Cloudflare credential and networking namespace; `wildcard-certificate`
creates the production issuer and wildcard certificate. A permanent staging issuer
and certificate are intentionally absent. Use a temporary staging resource only for
a deliberate future issuance experiment.

The Cloudflare token is scoped to Zone Read and DNS Edit for only
`supermorphic.com`. Its tracked Secret is SOPS encrypted. Use the Phase 7 Just
workflows in [`docs/phase-7-foundation.md`](../../../../docs/phase-7-foundation.md);
do not apply issuers or certificates directly.
