# cert-manager

cert-manager `v1.21.0` owns ACME DNS-01 issuance for the internal wildcard. The
Flux graph deliberately separates three readiness boundaries:

- `cert-manager` installs CRDs, webhook, cainjector, and controller;
- `cert-manager-config` proves the Cloudflare credential with Let's Encrypt staging;
- `wildcard-certificate` creates the production issuer and
  `networking/wildcard-lab-supermorphic-com-tls` only after staging is Ready.

The Cloudflare token is scoped to Zone Read and DNS Edit for only
`supermorphic.com`. Its tracked Secret is SOPS encrypted. Use the Phase 7 Just
workflows in [`docs/phases/phase-7-foundation.md`](../../../../docs/phases/phase-7-foundation.md);
do not apply issuers or certificates directly.
