# ExternalDNS Internal

ExternalDNS app `v0.21.0` (chart `1.21.1`) publishes internal Gateway API routes
to Pi-hole v6 at `https://pi.hole` (`192.168.90.2`). The deployment mounts the
reviewed public Pi-hole CA and verifies the server name; TLS verification is not
skipped. It is constrained to
`lab.supermorphic.com`, the `networking/internal` Gateway, and routes annotated
`external-dns.k8s.io/audience=internal`. Pi-hole has no TXT registry support, so
the controller uses `registry=noop` and `policy=upsert-only`.

The Pi-hole application password is stored only as SOPS ciphertext in Git. Use
`just repo phase7-secrets` to create it and the guarded foundation Just workflows in
the [root README](../../../../README.md) to validate or reconcile the controller. Fresh
Pi-hole installation, CA rotation, and application-password steps are in the
[Pi-hole integration guide](../../../../docs/guides/pihole-integration.md).
