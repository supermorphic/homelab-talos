# Phase 7: Internal Platform Foundation

## Status

- Prepared: 2026-07-19
- Completed: 2026-07-20
- State: Complete; the durable unsuspend and Talos node-label fix are reconciled
- Gateway hostname: `*.lab.supermorphic.com`
- Gateway address: `192.168.90.30`
- MetalLB pool: `192.168.90.30-192.168.90.39`
- DNS provider: Pi-hole v6 at `https://pi.hole` (`192.168.90.2`)

Phase 7 introduces the shared internal service path. It is deliberately private:
there is one internal HTTPS Gateway, no public Gateway, and ExternalDNS publishes
only explicitly annotated routes into Pi-hole.

## Architecture and Ownership

The foundation uses one production wildcard certificate for
`*.lab.supermorphic.com`, rather than issuing one certificate per service. The
certificate is stored only in the `networking` namespace and referenced by the
shared Gateway. Application namespaces attach `HTTPRoute` resources but do not
receive or copy the TLS private key.

```text
cert-manager -> staging issuer/certificate -> production issuer/certificate
                                                   |
MetalLB -> L2 pool ----------------------------> internal Gateway
Envoy Gateway ------------------------------------/       |
                                                           v
                                            Pi-hole ExternalDNS -> echo route
```

Flux splits controllers from their custom resources so CRDs and webhooks become
Ready before consumers reconcile. The nine units are initially committed with
`suspend: true` and resumed by `just bootstrap foundation` in this order:

1. `cert-manager`
2. `cert-manager-config` (staging ACME proof)
3. `wildcard-certificate` (production issuer and wildcard certificate)
4. `metallb`
5. `metallb-config`
6. `envoy-gateway`
7. `internal-gateway`
8. `external-dns-internal`
9. `echo`

If any stage fails, the bootstrap recipe re-suspends every attempted Phase 7
Kustomization and preserves the resources already created. It does not delete a
certificate, address pool, Gateway, or provider Secret.

## Pinned Components

| Component | Version | Source |
|---|---:|---|
| cert-manager | `v1.21.0` | Jetstack OCI chart |
| MetalLB | `0.16.1` | Official Helm repository |
| Envoy Gateway | `v1.8.2` | Envoy OCI chart |
| ExternalDNS app | `v0.21.0` | Official chart `1.21.1` |
| Echo image | `v1.5.1` | Kubernetes Gateway API example image |

MetalLB uses only L2 mode. Both FRR settings are disabled, the pool does not
auto-assign, and Envoy explicitly requests `192.168.90.30`. Envoy runs two
Gateway data-plane replicas with a disruption budget. ExternalDNS uses
`gateway-httproute`, Pi-hole API v6, `registry=noop`, `policy=upsert-only`, an
exact `lab.supermorphic.com` domain filter, and the internal-audience annotation
filter.

## Credential Preparation

Create a dedicated Cloudflare API token scoped only to the
`supermorphic.com` zone with:

- Zone / DNS / Edit
- Zone / Zone / Read

Create a dedicated Pi-hole v6 application password for ExternalDNS and enable
`webserver.api.app_sudo=true` so its session can modify custom DNS. ExternalDNS
uses `https://pi.hole` with the tracked public Pi-hole CA; TLS verification is
never skipped. The complete fresh-install, CA rotation, application-password,
and recovery procedure is in
[`pihole-integration.md`](../pihole-integration.md). Keep both provider credentials
in the password manager. Do not paste either credential into an issue, chat,
shell history, or tracked plaintext file.

Load the repository age identity and both provider values into one short-lived
shell session, then run the guarded writer:

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

The recipe validates the token with Cloudflare, proves it can read exactly the
target zone, authenticates to Pi-hole over verified HTTPS, and proves the
application password can create and remove a unique temporary DNS record. An
exit trap retries removal on every failure path. Only SOPS-encrypted Secret
manifests are moved into tracked source. Review the ciphertext metadata, run
validation, then commit and push the suspended Phase 7 source:

```bash
mise exec -- just kube foundation-validate
mise exec -- just repo verify
git status --short
```

Git commit and push remain explicit review actions; no Just recipe hides that
source-control boundary.

## Network Safety Gate

Before rollout, verify in the router configuration that
`192.168.90.30-192.168.90.39` is outside the DHCP allocation scope and is not
assigned by a reservation. ICMP silence alone does not prove an address is safe.
The bootstrap checks live Kubernetes LoadBalancer assignments and probes the
addresses, but it still requires the operator's explicit DHCP confirmation.

## Guarded Rollout

After the suspended source commit is on `origin/main`, fetch it into any clean
checkout, keep the age identity loaded, and run:

```bash
git fetch origin main
git status --short  # must print nothing
export PHASE7_NETWORK_CONFIRM='reserve:192.168.90.30-39:gateway:192.168.90.30'
export PHASE7_BOOTSTRAP_CONFIRM='bootstrap:phase7:internal-foundation:192.168.90.30'
mise exec -- just bootstrap foundation
unset PHASE7_NETWORK_CONFIRM PHASE7_BOOTSTRAP_CONFIRM SOPS_AGE_KEY
```

The recipe revalidates both provider credentials from SOPS ciphertext, confirms
the clean published Git boundary, checks all nine live children are suspended,
resumes them in dependency order, and runs the complete live acceptance gate.
Do not replace this workflow with raw `kubectl apply`, `helm install`, or
`flux resume` commands.

After the gate passes, change all Phase 7 `spec.suspend` fields to `false`,
review, commit, and push that durable desired state. When Flux has observed the
commit, run:

```bash
mise exec -- just kube foundation-status
mise exec -- just kube foundation-verify
```

## Exit Gate

The phase is complete only when the final verifier proves:

- all nine Phase 7 Flux Kustomizations are Ready and unsuspended;
- staging ACME completed before the production wildcard certificate became Ready;
- cert-manager's controller, webhook, and cainjector each have two available replicas;
- MetalLB has one controller, three speakers, the exact non-auto-assign pool,
  and no FRR workload;
- the GatewayClass is Accepted and the Gateway/listener are Programmed at
  `192.168.90.30`;
- two Envoy data-plane replicas are available;
- ExternalDNS carries every constrained Pi-hole argument;
- ExternalDNS mounts the tracked public Pi-hole CA, uses `https://pi.hole`, and
  does not skip TLS verification;
- Pi-hole resolves `echo.lab.supermorphic.com` only to `192.168.90.30`;
- HTTPS succeeds with normal certificate verification and returns an echo response;
- Cilium postflight, Talos diagnostics, and etcd health still pass.

## Acceptance Evidence

Recorded 2026-07-20. All nine Phase 7 Kustomizations are `suspend: false` and
Ready; the durable desired state is merged into `main`.

| Check | Observed |
|---|---|
| cert-manager | chart `cert-manager-1.21.0`; controller, webhook, cainjector Ready |
| MetalLB | chart `metallb-0.16.1`; controller + three speakers; no FRR workload |
| Envoy Gateway | chart `gateway-helm-1.8.2`; two data-plane replicas |
| ExternalDNS | chart `external-dns-1.21.1` (app `v0.21.0`); Pi-hole v6, `registry=noop`, `policy=upsert-only`, internal audience filter |
| Staging ACME | `wildcard-lab-supermorphic-com-staging` Ready before production issuance |
| Wildcard certificate | `wildcard-lab-supermorphic-com` Ready from `letsencrypt-production` |
| Gateway | `internal` Programmed at `192.168.90.30` |
| MetalLB announcement | L2 announced from `nuc2` (`servicel2status`) |
| Internal DNS | Pi-hole resolves `echo.lab.supermorphic.com` to `192.168.90.30` |
| Trusted HTTPS | `https://echo.lab.supermorphic.com` returns HTTP `200` with the wildcard certificate |
| Platform health | Cilium postflight clean, three etcd members, no etcd alarms |

### Live rollout note: MetalLB on all-control-plane nodes

The first rollout deployed cleanly but MetalLB never announced the Gateway IP.
Root cause: all three nodes are control planes, and Talos adds
`node.kubernetes.io/exclude-from-external-load-balancers` to control-plane nodes
via `machine.nodeLabels` and reconciles it; MetalLB honors that label and reports
"no available nodes". Removing it with `kubectl label` does not persist because
Talos re-applies it from the machine config. The durable fix deletes the label in
`talos/patches/machine.yaml` (`$$patch: delete`, escaped for talhelper's env
substitution) and is applied to each running node with the guarded
`just talos apply-live <node>` recipe in `--mode=no-reboot`. See
[`../../kubernetes/apps/networking/metallb/README.md`](../../kubernetes/apps/networking/metallb/README.md).
