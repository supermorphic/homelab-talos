# SOPS Secret Handling

This repository uses a dedicated age identity for the fresh Talos and Flux
platform. Only its public recipient is committed. The private identity stays in
the password-manager item `homelab-talos SOPS age key`.

## Load the Repository Identity

Load the private identity for one shell:

```bash
export SOPS_AGE_KEY='AGE-SECRET-KEY-...'
mise exec -- just repo secrets
```

Alternatively, point SOPS at an owner-readable file outside the repository:

```bash
export SOPS_AGE_KEY_FILE=/secure/path/homelab-talos-age.txt
mise exec -- just repo secrets
```

The check derives the public recipient and rejects an identity that does not
match the first rule in `.sops.yaml`.

## Encryption Policy

- `talos/talsecret.sops.yaml` is encrypted as a complete document because every
  field is cluster identity material.
- `kubernetes/**/*.sops.yaml` encrypts only `data` and `stringData`, leaving
  Secret metadata reviewable.
- Plaintext secrets, decrypted files, kubeconfigs, talosconfigs, and private age
  identities must never be committed.

The Talos identity was generated once with `talhelper gensecret` under an owner-
only umask and encrypted immediately to `talos/talsecret.sops.yaml`. The plaintext
temporary file was removed after the initial render. Do not regenerate this file:
doing so creates a different cluster identity.

`just talos generate` requires `SOPS_AGE_KEY` or `SOPS_AGE_KEY_FILE`, verifies the
loaded identity with `just repo secrets`, and lets Talhelper decrypt the tracked
bundle while rendering ignored output. `just bootstrap flux-sops` validates the same identity and creates
`flux-system/sops-age` without exposing the private key in Git or command output.
An existing matching Secret is left unchanged; a mismatched Secret is never
overwritten by that workflow. The permanent encrypted `flux-canary` Secret proves
that in-cluster decryption remains functional.

Foundation provider credentials are created only through
`just repo phase7-secrets`. The workflow validates a zone-scoped Cloudflare token
and proves a dedicated Pi-hole v6 application password can create and remove a
temporary record over CA-verified HTTPS. It writes plaintext only inside an
owner-readable temporary directory, encrypts each Secret for the repository
recipient, and moves only ciphertext into the tracked application directories.
Exact environment variables and confirmation text are part of the guarded recipe;
Pi-hole reinstall and trust-anchor rotation are in
[Maintain the Pi-hole integration](pihole-integration.md).
