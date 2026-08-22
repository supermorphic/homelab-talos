# Maintain the Pi-hole integration

## Scope and ownership

Pi-hole is external infrastructure at `192.168.90.2`, reached over SSH as `p1`
and over its API as `https://pi.hole`. It remains managed outside this
repository. `homelab-talos` owns only the ExternalDNS integration that publishes
explicitly annotated `lab.supermorphic.com` Gateway routes into Pi-hole custom
DNS.

The integration deliberately uses:

- Pi-hole v6's native API;
- a separate Pi-hole application password, never the interactive admin password;
- `webserver.api.app_sudo=true`, because custom DNS records are configuration;
- Pi-hole's generated HTTPS CA pinned as public Git source;
- `https://pi.hole`, matching the certificate name;
- certificate verification, with no `pihole-tls-skip-verify` escape hatch;
- SOPS ciphertext for the application password.

The application password is revocable but is not a scoped PAT. Pi-hole v6 uses
it to create short-lived API sessions. Enabling `app_sudo` gives those sessions
broad configuration-write permission, so dedicate the password to ExternalDNS
and rotate it if the cluster or credential is compromised.

Run every repository command below from the root of the assigned feature
worktree. Do not run a CA refresh or SOPS writer from the primary checkout: both
workflows can replace tracked files in the current worktree. Before continuing,
confirm the current directory is the intended worktree and its repository root:

```bash
test "$(git rev-parse --show-toplevel)" = "$PWD"
git status --short --branch
```

Stop unless that output identifies the assigned feature worktree rather than the
primary checkout.

## Run the read-only check

Run this after Pi-hole maintenance and before provider-credential or foundation
operations:

```bash
mise exec -- just repo pihole-status
```

The check uses the reviewed SSH identity for `p1`, verifies that HTTPS is active
for `pi.hole`, requires `app_sudo=true`, compares the live public CA byte-for-byte
with the tracked CA, and calls the Pi-hole version endpoint with certificate
verification enabled. It never requests an application password.

## Prepare Pi-hole after a fresh install

Complete these steps before updating `homelab-talos`:

1. Restore Pi-hole v6 and Unbound according to the external infrastructure
   procedure. Keep Pi-hole at `192.168.90.2` and keep the `p1` SSH host identity
   reviewed on the workstation.
2. Confirm the Pi-hole web-server domain is `pi.hole` and that its listener
   includes encrypted port `443`. Pi-hole v6 normally generates
   `/etc/pihole/tls_ca.crt` and enables HTTPS during installation.
3. Allow trusted application-password sessions to modify configuration:

   ```bash
   ssh p1 'sudo pihole-FTL --config webserver.api.app_sudo true'
   ssh p1 'sudo pihole-FTL --config webserver.api.app_sudo'
   ```

   The second command must print `true`.
4. Sign in to the Pi-hole administration UI and open **Settings → Web
   interface / API**. Switch to **Expert** if needed, select **Configure app
   password**, generate a new password, and copy it immediately. Pi-hole shows it
   only once.
5. Store the value in the password manager as
   `homelab-talos / ExternalDNS / Pi-hole`. Do not send it through chat, commit it,
   or place it directly in a shell command.

Do not copy `/etc/pihole/tls.pem` or any private key into this repository. Only
the public `/etc/pihole/tls_ca.crt` trust anchor is tracked.

## Refresh the public CA after reinstall or rotation

A fresh Pi-hole installation normally creates a new CA. Until Git and Flux carry
that CA, ExternalDNS fails closed with a certificate error.

Use the guarded workflow to retrieve only the public CA through the reviewed
`p1` SSH connection:

```bash
export PIHOLE_CA_REFRESH_CONFIRM='refresh:pihole-ca:p1:pi.hole'
mise exec -- just repo pihole-ca-refresh
unset PIHOLE_CA_REFRESH_CONFIRM
```

The recipe checks the Pi-hole domain, HTTPS listener, CA constraints, self-
signature, and expiry. It prints the old and new SHA-256 fingerprints and changes
only `kubernetes/apps/networking/external-dns/app/pihole-ca.crt`.

Review the certificate change and re-run the read-only gate:

```bash
git diff -- kubernetes/apps/networking/external-dns/app/pihole-ca.crt
mise exec -- just repo pihole-status
```

The CA is public, but changing it changes which server ExternalDNS trusts. Treat
the diff as a security-sensitive trust-anchor rotation and verify the displayed
fingerprint against the Pi-hole host before committing.

## Replace the SOPS-encrypted application password

The guarded writer also validates the Cloudflare token used by cert-manager, so
load both provider values. Hidden reads keep their literal values out of shell
history:

```bash
printf 'SOPS age private key: '
read -rs SOPS_AGE_KEY
printf '\n'
export SOPS_AGE_KEY

printf 'Cloudflare API token: '
read -rs CLOUDFLARE_API_TOKEN
printf '\n'
export CLOUDFLARE_API_TOKEN

printf 'Pi-hole application password: '
read -rs PIHOLE_PASSWORD
printf '\n'
export PIHOLE_PASSWORD

export PHASE7_SECRETS_CONFIRM='write:phase7:cloudflare-and-pihole:sops'
mise exec -- just repo phase7-secrets
unset PHASE7_SECRETS_CONFIRM CLOUDFLARE_API_TOKEN PIHOLE_PASSWORD SOPS_AGE_KEY
```

If the age identity already lives in an owner-readable file, set
`SOPS_AGE_KEY_FILE` to that file instead of loading `SOPS_AGE_KEY`.

The writer performs all of the following before replacing tracked ciphertext:

1. Verifies the repository age recipient.
2. Validates the Cloudflare token and exact `supermorphic.com` zone access.
3. Authenticates to `https://pi.hole` using the pinned CA.
4. Creates a unique temporary A record under `lab.supermorphic.com` pointing to
   the documentation-only address `192.0.2.1`.
5. Reads the record back, deletes it, and verifies its removal.
6. Logs out of the short-lived Pi-hole session.
7. Writes only SOPS-encrypted Secret manifests into tracked source.

An exit trap attempts record removal on every failure path. If cleanup cannot be
proven, the recipe fails and prints the exact temporary record to remove in
Pi-hole's Local DNS UI before retrying.

## Validate, publish, and reconcile

Validate the complete foundation source after either CA or password rotation:

```bash
mise exec -- just kube foundation-validate
mise exec -- just repo verify
git status --short
```

Review, commit, and push the CA and/or SOPS ciphertext changes explicitly. Git
push remains a human review boundary and is not hidden inside a Just recipe.

Flux reconciles the committed change. Check it with:

```bash
mise exec -- just kube foundation-status
mise exec -- just kube foundation-verify
```

## Rotation and failure behavior

- Revoking or replacing the application password requires rerunning
  `just repo phase7-secrets`, committing the new ciphertext, and reconciling Flux.
- Replacing Pi-hole or regenerating its TLS material requires
  `just repo pihole-ca-refresh`, security review of the CA diff, and a Git commit.
- A CA mismatch, wrong hostname, expired certificate, read-only application
  session, failed temporary write, or failed deletion stops the workflow.
- Never work around a CA failure with `pihole-tls-skip-verify` or by returning the
  provider URL to HTTP.
- Existing DNS records remain in Pi-hole while ExternalDNS is unable to connect;
  `policy=upsert-only` prevents it from deleting unrelated manually managed
  records after recovery.
