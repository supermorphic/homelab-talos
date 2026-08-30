# Operate the Pi-hole ExternalDNS integration

## Purpose and integration flow

Pi-hole provides DNS for the LAN. ExternalDNS connects Kubernetes routes to that
external DNS service:

```text
annotated HTTPRoutes and DNSEndpoints
        ↓
ExternalDNS in Kubernetes
        ↓
verified HTTPS to https://pi.hole
  ├─ tracked Pi-hole public CA
  └─ dedicated Pi-hole application password
        ↓
Pi-hole custom DNS
        ↓
lab.supermorphic.com names resolve to the internal Gateway on the LAN
```

ExternalDNS watches Gateway API routes that:

- attach to the `internal` Gateway;
- use a name under `lab.supermorphic.com`; and
- carry `external-dns.k8s.io/audience=internal`.

It also watches `DNSEndpoint` resources carrying the same audience annotation. The
public webhook Gateway package uses this source for
`hooks.lab.supermorphic.com -> 192.168.90.39` because its public HTTPRoute remains absent
until activation. The domain filter and managed A-record restriction apply to both
source types. This internal record does not update the public Cloudflare DNS zone.

It manages only A records. Its `upsert-only` policy permits record creation and
updates, but not deletion. This protects manually managed Pi-hole records. It also
means a record can remain after its Kubernetes source is removed and may require
manual cleanup.

## Ownership boundary

Pi-hole and Unbound are external infrastructure. Their installation, backup,
restore, host operating system, network address, and interactive administration
remain outside this repository. The workstation reaches the Pi-hole host through
the configured SSH alias `p1`; the API endpoint is `https://pi.hole`.

`homelab-talos` owns:

- the ExternalDNS deployment and provider settings;
- the annotated Kubernetes routes and `DNSEndpoint` resources that become internal DNS
  records;
- the reviewed public Pi-hole CA used as a trust anchor;
- the SOPS-encrypted Pi-hole application password; and
- rollout stamps that replace the ExternalDNS Pod when the password or CA changes.

Git does not prove the current Pi-hole version or the state of settings stored only
on the external host. Verify those through the Pi-hole administration interface or
the host's supported commands.

## Security model

The integration uses Pi-hole v6's native API over verified TLS:

- ExternalDNS connects to `https://pi.hole`, which matches the certificate name.
- The public `/etc/pihole/tls_ca.crt` CA is reviewed and tracked in Git. The server
  certificate `/etc/pihole/tls.pem`, its private key, and all other private key
  material stay out of Git.
- TLS verification remains enabled. There is no
  `pihole-tls-skip-verify` fallback.
- The application password is stored only as SOPS ciphertext in Git.
- ExternalDNS uses a dedicated application password, not the interactive Pi-hole
  administrator password.

Pi-hole application passwords are not narrowly scoped personal access tokens.
ExternalDNS must create and update custom DNS records, so Pi-hole requires
`webserver.api.app_sudo=true`. With that setting, an authenticated application-
password session can modify broad Pi-hole configuration, including settings outside
DNS records. Keep this password dedicated to ExternalDNS and rotate it if its
confidentiality is uncertain.

## When operator action is needed

| Situation | Action |
| --- | --- |
| Normal operation | None. ExternalDNS continuously publishes eligible records. |
| Ordinary Pi-hole maintenance | Run the read-only Pi-hole status check. |
| Pi-hole reinstall, domain change, or TLS regeneration | Refresh and review the tracked public CA. |
| Pi-hole application-password replacement or revocation | Regenerate the encrypted provider Secrets. |
| A tracked CA, Secret, or rollout stamp changes | Validate, review, publish through a pull request, wait for Flux, and run live verification. |
| Deliberately suspended greenfield foundation | Follow the exceptional `bootstrap foundation` workflow; it is not routine maintenance. |

## Command effects and authority

Confirmation variables are execution guards. They make an exact target and action
visible before a command runs, but they do not decide who owns the operation.
Authority comes from `AGENTS.md` and from the credentials or external state the
workflow uses.

| Command | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just repo pihole-status` | Reads Pi-hole host configuration and checks the live TLS identity against Git. | Read-only, but operator-run because it uses the operator's external `p1` SSH and `sudo` access. |
| `mise exec -- just repo pihole-ca-refresh` | Retrieves the public CA, validates it, and updates the tracked CA and rollout stamp. | Mutates repository files and changes a security-sensitive trust decision; operator-run. |
| `mise exec -- just repo foundation-provider-secrets` | Validates both providers, temporarily creates and removes one Pi-hole DNS record, and writes encrypted Secrets plus the rollout stamp. | Uses operator-held plaintext credentials and the SOPS age identity, mutates external Pi-hole state temporarily, and mutates repository files; operator-run. |
| `mise exec -- just kube foundation-validate` | Validates local source, encrypted Secret shape, CA policy, rollout stamps, dependencies, and pinned Helm renders. | Cluster-independent and read-only; agent-owned when relevant. |
| `mise exec -- just repo validate` | Runs repository, Talos-source, and secret-leak checks. | Cluster-independent and read-only; agent-owned. |
| `mise exec -- just kube foundation-status` | Prints live Flux, controller, certificate, Gateway, DNS, and workload state. | Read-only scoped cluster observation; agent-owned for an approved task. |
| `mise exec -- just kube foundation-verify` | Runs the complete live foundation acceptance gate, including the deployed ExternalDNS rollout stamps. | Read-only scoped verification; agent-owned for an approved task. |

## Check the current Pi-hole integration

Run this after ordinary Pi-hole maintenance and before changing provider
credentials or trust:

```bash
mise exec -- just repo pihole-status
```

### What it proves

The command proves that:

- the configured `p1` SSH connection and non-interactive `sudo` access work;
- the Pi-hole web-server domain is `pi.hole`;
- the listener configuration includes HTTPS;
- `webserver.api.app_sudo` is `true`;
- Pi-hole answers `pi.hole` at its expected LAN address;
- the live public CA is self-signed, remains valid for more than 30 days, and
  matches the tracked CA byte-for-byte; and
- a certificate-verified request to the Pi-hole v6-compatible
  `/api/info/login` endpoint succeeds.

### What it does not prove

The command does not:

- report or verify the exact installed Pi-hole version;
- authenticate with the ExternalDNS application password;
- prove that an authenticated session can create or delete a DNS record;
- prove that Flux has deployed the latest encrypted Secret; or
- prove that the running ExternalDNS Pod has accepted a new provider credential.

The guarded Secret writer supplies the temporary write/delete proof. The live
foundation verifier supplies the Flux, Deployment, rollout-stamp, DNS, and Gateway
acceptance checks.

## Prepare or rebuild Pi-hole

These steps change the external Pi-hole system. They are required after a genuine
reinstall or when restoring a Pi-hole instance that does not yet satisfy the
integration contract.

1. Install or restore Pi-hole v6 and Unbound through the external infrastructure
   procedure. Preserve the expected LAN address and review the workstation's `p1`
   SSH host identity.
2. Confirm that Pi-hole's configured web-server domain is `pi.hole` and its
   listener includes HTTPS on port 443. Pi-hole normally creates
   `/etc/pihole/tls_ca.crt` for its generated certificate.
3. Permit application-password sessions to update configuration:

   ```bash
   ssh p1 'sudo pihole-FTL --config webserver.api.app_sudo true'
   ssh p1 'sudo pihole-FTL --config webserver.api.app_sudo'
   ```

   The second command must print `true`.
4. In the current Pi-hole v6 administration interface, open the settings page for
   the web interface and API. Use **Configure application password**, enable a new
   application password, and copy it immediately. Pi-hole shows it only once.
   Interface navigation can move between Pi-hole releases; the dialog purpose and
   title are the durable identifiers.
5. Store the value in the operator's password manager as the dedicated ExternalDNS
   credential. Do not send it through chat, commit it, or place it literally in a
   shell command.

Creating a new application password replaces the existing one and invalidates
existing application sessions. The current repository does not stage two Pi-hole
passwords at once, so rotation causes a planned interruption until the encrypted
replacement reaches the ExternalDNS Pod.

Do not copy `/etc/pihole/tls.pem` or a private key into this repository. Only the
public `/etc/pihole/tls_ca.crt` trust anchor is tracked.

## Before changing tracked trust or credentials

The CA refresh and provider-Secret recipes write into the current checkout. They do
not themselves reject the primary checkout. Run them only from the assigned feature
worktree, confirm that it is the intended repository root, and preserve unrelated
changes:

```bash
test "$(git rev-parse --show-toplevel)" = "$PWD"
git status --short --branch
```

Stop if the output identifies the primary checkout, an unexpected branch, or
unrelated changes that overlap the files this operation will write.

## Refresh the trusted public CA

A reinstall, configured-domain change, or TLS regeneration can create a new Pi-hole
CA. Until the reviewed replacement reaches the running ExternalDNS Pod, certificate
verification fails closed:

```text
Pi-hole receives a new public CA
  → tracked CA no longer matches
  → ExternalDNS rejects the TLS connection
  → retrieve and validate only the new public CA
  → review its fingerprint and Git diff
  → publish through Git and let Flux reconcile
  → rollout stamp replaces the ExternalDNS Pod
  → live verification proves the deployed revision and DNS path
```

Run the guarded refresh from the feature worktree:

```bash
export PIHOLE_CA_REFRESH_CONFIRM='refresh:pihole-ca:p1:pi.hole'
mise exec -- just repo pihole-ca-refresh
unset PIHOLE_CA_REFRESH_CONFIRM
```

The recipe:

- reads `/etc/pihole/tls_ca.crt` through `p1`;
- checks the configured domain and HTTPS listener;
- rejects private-key material;
- requires a self-signed CA certificate with `CA:TRUE` and more than 30 days of
  remaining validity;
- prints the old and new SHA-256 fingerprints;
- updates `kubernetes/apps/networking/external-dns/app/pihole-ca.crt`; and
- updates the CA-derived ExternalDNS Pod rollout stamp in
  `kubernetes/apps/networking/external-dns/app/values.yaml`.

If the CA already matches but the rollout stamp is stale, the recipe repairs only
the stamp. The CA is public, but replacing it changes which server ExternalDNS
trusts. Review both the fingerprint and the exact Git diff before publishing.

## Rotate the ExternalDNS application password

The current repository has one combined writer for the cert-manager Cloudflare
token and the ExternalDNS Pi-hole password. Therefore a Pi-hole password rotation
requires both current provider values. The command validates and rewrites both
encrypted Secrets even when only one credential changed. This coupling is retained
implementation behavior, not a requirement imposed by Pi-hole or ExternalDNS.

Load the operator-held values without placing them in shell history:

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

export FOUNDATION_PROVIDER_SECRETS_CONFIRM='write:foundation-providers:cloudflare-and-pihole:sops'
mise exec -- just repo foundation-provider-secrets
unset FOUNDATION_PROVIDER_SECRETS_CONFIRM CLOUDFLARE_API_TOKEN PIHOLE_PASSWORD SOPS_AGE_KEY
```

If the age identity already exists in an owner-readable file, set
`SOPS_AGE_KEY_FILE` instead of loading `SOPS_AGE_KEY`.

The writer does more than check the password:

```text
validate the repository age recipient and Cloudflare token
  → authenticate to Pi-hole through the pinned CA
  → create one unique provider-preflight-*.lab.supermorphic.com A record
  → point it to the RFC 5737 documentation address 192.0.2.1
  → read the record back
  → delete it
  → prove it is absent
  → log out of the Pi-hole session
  → encrypt both provider Secrets
  → update the Pi-hole Secret rollout stamp
  → replace only the tracked ciphertext and rollout configuration
```

An exit trap attempts cleanup on every failure path. If cleanup cannot be proven,
the command stops and prints the exact temporary record. Remove that exact record
through Pi-hole's custom/local DNS interface and prove it is gone before retrying.

The writer never prints the plaintext provider values. Git receives only SOPS
ciphertext. The Pi-hole Secret's Git blob revision becomes part of the ExternalDNS
Pod template, so Flux replaces the Pod and the process reads the new password.

## Validate, publish, reconcile, and verify

After changing the CA, provider Secrets, or rollout stamps, follow the complete
lifecycle:

```text
tracked source changes
  → local source and security validation
  → review the exact diff
  → commit, push, and open a pull request
  → merge through protected main
  → Flux reconciles the Secret, ConfigMap, values, and Deployment
  → ExternalDNS Pod is replaced when a source revision changed
  → live verification checks the deployed revisions and DNS path
```

Run the local gates:

```bash
mise exec -- just kube foundation-validate
mise exec -- just repo validate
git diff -- \
  kubernetes/apps/networking/external-dns/app/pihole-ca.crt \
  kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml \
  kubernetes/apps/networking/external-dns/app/values.yaml \
  kubernetes/apps/security/cert-manager/config/cloudflare-api-token.sops.yaml
git status --short
```

Review and publish the intended files through the normal protected pull-request
workflow. Do not apply durable Flux-managed changes directly to the cluster.

After merge, allow Flux to reconcile. Then run:

```bash
mise exec -- just kube foundation-status
mise exec -- just kube foundation-verify
```

`foundation-status` is a readable snapshot. `foundation-verify` is the acceptance
gate. It validates local source, requires the foundation Flux objects and workloads
to be ready, checks that the live ExternalDNS Deployment carries the exact CA and
encrypted-Secret revisions from Git, waits for its rollout, validates its provider
arguments and mounted CA, confirms Pi-hole DNS for the echo route, proves HTTPS
through the internal Gateway, and checks the remaining Talos, etcd, and Cilium
foundation health.

It does not create another Pi-hole record or independently recover the plaintext
application password. The earlier guarded writer's create/read/delete transaction is
the credential-write acceptance test.

## Failure and recovery

### Application password replaced or revoked

ExternalDNS authentication fails until the replacement is encrypted, reviewed,
merged, reconciled, and loaded by the replacement Pod. Run
`foundation-provider-secrets`, publish all resulting files, then run the live
foundation verifier.

### Pi-hole rebuilt or TLS material changed

ExternalDNS rejects the new certificate until the reviewed CA and its rollout stamp
reach the replacement Pod. Run `pihole-ca-refresh`, review the trust change, publish
it, and run the live verifier.

### TLS mismatch, wrong hostname, or invalid certificate

The status check, provider writer, and ExternalDNS connection fail closed. Correct
the host domain or rotate the reviewed CA. Do not switch the provider to HTTP and do
not enable `pihole-tls-skip-verify`.

### Temporary DNS write or cleanup fails

The Secret writer stops without accepting the integration. If it cannot prove
cleanup, use the exact hostname printed in its error, remove only that record in
Pi-hole, and verify its absence before retrying. Do not ignore an uncertain cleanup.

### ExternalDNS is unavailable

Existing records remain in Pi-hole, so already-published names can continue to
resolve. New records and updates do not appear until ExternalDNS recovers.
`upsert-only` also means ExternalDNS does not remove records whose Kubernetes source
disappears; clean up stale records deliberately when required.

### Deliberately suspended first installation

Routine credential or CA rotation does not require bootstrap. Use
`mise exec -- just bootstrap foundation` only for the repository's deliberately
staged, suspended foundation initialization. That workflow uses elevated credentials
and changes live Flux state, so it remains outside this normal maintenance guide.

## Implementation reference

| Artifact | Role |
| --- | --- |
| `kubernetes/apps/networking/external-dns/app/values.yaml` | Provider URL, v6 API, source filters, `upsert-only`, CA mount, password reference, and rollout stamps. |
| `kubernetes/apps/networking/external-dns/app/pihole-ca.crt` | Reviewed public Pi-hole CA trust anchor. |
| `kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml` | SOPS-encrypted dedicated Pi-hole application password. |
| `kubernetes/apps/networking/external-dns/app/kustomization.yaml` | Generates the CA ConfigMap and ExternalDNS values ConfigMap. |
| `scripts/repository/stamp-external-dns-provider.sh` | Derives Pod rollout annotations from the CA and encrypted Secret Git blobs. |
| `scripts/validate/external-dns-provider-revisions.sh` | Requires source, rendered, and live Deployment revisions to agree. |
| `scripts/validate/foundation.sh` | Validates the complete local foundation contract and pinned chart renders. |
| `scripts/verify/foundation.sh` | Verifies the reconciled live foundation and DNS-to-HTTPS path. |

Upstream behavior references:

- [Pi-hole configuration reference](https://docs.pi-hole.net/ftldns/configfile/)
- [Pi-hole API authentication](https://docs.pi-hole.net/api/auth/)
- [Pi-hole TLS and public CA guidance](https://docs.pi-hole.net/api/tls/)
- [ExternalDNS Pi-hole provider guidance](https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/pihole/)
