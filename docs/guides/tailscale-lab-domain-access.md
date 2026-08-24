# Access the lab domain over Tailscale

This guide operates private access to `*.lab.supermorphic.com` from authorized Tailscale
clients. Off-LAN clients use the same application URLs, certificates, Gateway, and
authentication that they use on the home LAN.

This is a different path from a ProxyGroup-backed Tailscale Service such as ntfy.

## Same-URL access model

```text
tailnet client
      ↓
restricted nameserver for lab.supermorphic.com
      ↓
Connector route to Pi-hole 192.168.90.2/32
      ↓
hostname resolves to 192.168.90.30
      ↓
Connector route to Gateway VIP 192.168.90.30/32
      ↓
existing Envoy Gateway + HTTPRoutes
      ↓
https://<app>.lab.supermorphic.com
```

The Connector supplies private IP routing. Tailscale split DNS sends only the lab domain
to Pi-hole. Envoy Gateway terminates the repository's existing wildcard certificate and
routes by hostname. Each application still enforces its own authentication.

Adding another application that follows the existing internal Gateway and ExternalDNS
contract normally needs no Tailscale change.

## Ownership

| Owner | Responsibility |
| --- | --- |
| Git and Flux | `Connector/lab-subnet-router`, `ProxyClass/lab-subnet-router`, exact advertised routes, application HTTPRoutes, and Kubernetes desired state |
| Tailscale control plane | Connector devices, route auto-approval, client route distribution, Access controls, and restricted nameserver settings |
| Pi-hole and ExternalDNS | `lab.supermorphic.com` answers that point application names to the internal Gateway VIP |
| Envoy Gateway | TLS termination and hostname routing on the shared internal VIP |
| Applications | Login, authorization, and session policy |

The tailnet policy is external operator-managed state. This guide records only the
`tag:lab-router`, route approval, DNS, and Gateway access relationships required by this
feature.

## Least-privilege route boundary

The Connector advertises exactly two host routes:

```text
192.168.90.2/32    Pi-hole DNS resolver
192.168.90.30/32   Envoy internal Gateway VIP
```

Do not advertise the full LAN `/24`, Pod CIDR, or Service CIDR. The client needs only one
DNS resolver and one HTTPS entry point. A broader route would expose unrelated network
destinations without helping this design.

Route injection and Access controls are separate gates. An approved route tells the
client where to send traffic; a grant decides whether that traffic is permitted. Both
must be correct. See Tailscale's [route injection documentation](https://tailscale.com/docs/reference/route-injection).

## When operator action is needed

| Situation | Action |
| --- | --- |
| Normal operation | None |
| New app on the existing lab Gateway | Usually no Tailscale change; verify its normal DNS, HTTPRoute, TLS, and app authentication |
| Deliberately suspended fresh/rebuilt Connector | Use the guarded subnet-router bootstrap after policy prerequisites are saved |
| DNS resolver replacement | Add the new exact route and restricted nameserver, migrate and test clients, then remove the old path |
| Gateway VIP change | Add the new exact route and grant, update source and DNS, test, then remove the old path |
| New human tailnet user | Replace `autogroup:member` with a reviewed group before admitting the user |
| Client failure | Diagnose Tailscale connection, route approval, split DNS, Gateway, then the application |

## Command effects and authority

| Operation | What it does | Effect and authority |
| --- | --- | --- |
| Access controls or DNS change | Changes external tailnet policy or DNS behavior | Operator-managed external mutation |
| `mise exec -- just kube tailscale-subnet-router-validate` | Validates source, exact routes, tag, replicas, spread, Kustomization, and no-Funnel boundary | Local, read-only, agent-owned |
| `mise exec -- just kube tailscale-subnet-router-verify` | Observes Connector reconciliation, devices, Pods, routes, Gateway, and a representative HTTPRoute | Approved scoped observer verification; agent-autonomous when the task needs it |
| `mise exec -- just bootstrap tailscale-subnet-router` | Resumes and reconciles a deliberately suspended Connector deployment | Exceptional privileged live mutation; operator-run unless explicitly authorized for that invocation |
| **Machines** route inspection | Checks external route approval on both Connector devices | Operator external-state inspection |
| Mac/iPhone acceptance | Proves real routing, DNS, TLS, and application behavior | Human functional acceptance |

## Add the lab-router policy fragment

The Operator OAuth identity must own `tag:lab-router` before the Connector creates its
devices. Merge these relationships into the current policy in **Access controls**:

```jsonc
"tagOwners": {
  "tag:lab-router": ["tag:k8s-operator"]
},
"autoApprovers": {
  "routes": {
    "192.168.90.2/32": ["tag:lab-router"],
    "192.168.90.30/32": ["tag:lab-router"]
  }
},
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["192.168.90.2/32"],
    "ip": ["tcp:53", "udp:53"]
  },
  {
    "src": ["autogroup:member"],
    "dst": ["192.168.90.30/32"],
    "ip": ["tcp:443"]
  }
]
```

These are fragments, not a complete replacement policy. Preserve unrelated current
entries and review the Admin Console diff before saving.

`autogroup:member` is acceptable only for the current single-user tailnet. Before adding
another human user, replace it with a reviewed group. All applications share
`192.168.90.30:443`, so this network-layer grant cannot distinguish one hostname from
another. Application authentication remains the per-application boundary.

Do not manually approve a route to work around missing `autoApprovers.routes`. That would
hide a policy defect and leave replacement Connector devices unapproved.

## Validate source

Run:

```bash
mise exec -- just kube tailscale-subnet-router-validate
```

The validator checks:

- the Connector Kustomization depends on the Operator;
- `hostnamePrefix: lab-subnet-router` is used for the two replicas;
- the Connector carries only `tag:lab-router`;
- advertised routes are exactly the two approved `/32`s;
- broad LAN, Pod, and Service routes are absent;
- the ProxyClass uses a hard one-per-node topology spread; and
- Funnel is absent.

It does not contact the tailnet or prove route approval, DNS, or client traffic.

## Bootstrap a deliberately suspended Connector

Current source is active with `spec.suspend: false`. Use bootstrap only for a fresh or
rebuilt Connector deliberately staged suspended through Git.

Before bootstrap:

1. save the `tag:lab-router` ownership, auto-approval, and grant fragments;
2. publish the suspended Connector source through the normal pull-request path; and
3. confirm the Tailscale Operator is already healthy.

Then use the authorized administrative path:

```bash
TAILSCALE_SUBNET_ROUTER_BOOTSTRAP_CONFIRM='bootstrap:networking:tailscale-subnet-router' \
  mise exec -- just bootstrap tailscale-subnet-router
```

The recipe requires the relevant source to match deployed `main`, validates both source
and live suspension, resumes only `tailscale-operator-subnet-router`, waits for it, and
runs the live verifier. If it fails after resume, cleanup re-suspends that Kustomization
and preserves its resources.

After route and client acceptance, use a separate reviewed Git change to make
`spec.suspend: false` durable. Do not use bootstrap for ordinary reconciliation.

## Verify structural state

Run:

```bash
mise exec -- just kube tailscale-subnet-router-verify
```

### What it proves

- the subnet-router Flux Kustomization is Ready;
- `Connector/lab-subnet-router` is `ConnectorReady`;
- the Connector reports two devices;
- two running Connector Pods are on distinct nodes;
- both spec and status report exactly the two `/32` routes;
- the internal Gateway is Programmed;
- the representative Homepage HTTPRoute is Accepted; and
- when reachable from the workstation, Pi-hole returns the Gateway VIP for the
  representative hostname.

The command then runs the shared foundation verifier. A later shared-foundation failure
does not erase earlier successful Connector assertions.

### What it does not prove

- that Tailscale approved either route;
- that both Connector devices are eligible to carry traffic;
- that the restricted nameserver exists;
- that a Mac or iPhone received the routes;
- that browser HTTPS succeeds; or
- that an application login works.

The three evidence layers are therefore:

```text
repository/live verifier  → Connector structure and reconciliation
Admin Console             → route auto-approval on both devices
real client               → usable DNS, routing, TLS, and application access
```

## Confirm route auto-approval

Open **Machines** in the Tailscale Admin Console. Locate both
`lab-subnet-router-*` devices, open their subnet-route details, and confirm:

- each device advertises and has approval for `192.168.90.2/32`;
- each device advertises and has approval for `192.168.90.30/32`; and
- neither device advertises another subnet.

The two replicas must both carry the same exact routes for failover. Connector
`.status.subnetRoutes` mirrors the configured routes in Operator 1.98.9; it is a
reconciliation signal, not an independent approval oracle. Tailscale documents route
approval and the **Machines** subnet controls in its
[subnet-router guide](https://tailscale.com/docs/features/subnet-routers).

## Configure split DNS

Open **DNS** in the Admin Console and add `192.168.90.2` as a custom **restricted
nameserver** for `lab.supermorphic.com`. A restricted nameserver is Tailscale's current
term for split DNS: only names under that domain go to Pi-hole.

Keep the current MagicDNS setting used by the Operator service foundation. Do not enable
**Override DNS servers** for this feature; Pi-hole is not meant to replace every client's
ordinary global resolver.

Routing and DNS are both required:

- without the resolver `/32`, the client cannot reach Pi-hole;
- without the restricted nameserver, the client does not ask Pi-hole for the lab zone;
- without the Gateway `/32`, the private DNS answer is unreachable; and
- without the grants, routed traffic remains denied.

See Tailscale's current [DNS model](https://tailscale.com/docs/reference/dns-in-tailscale).

## Accept the path from a Mac

Run this off the home LAN with Tailscale connected:

```bash
# The restricted resolver must be selected for the lab domain.
tailscale dns status
# On macOS, this also shows resolver ordering and scoped domains.
scutil --dns

# The exact Gateway host route must use the Tailscale interface.
route -n get 192.168.90.30

# The private resolver must return the internal Gateway VIP.
dscacheutil -q host -a name homepage.lab.supermorphic.com

# TLS must validate normally. Never use -k for acceptance.
curl -I https://homepage.lab.supermorphic.com
curl -I https://grafana.lab.supermorphic.com
curl -I https://portainer.lab.supermorphic.com
```

Confirm the resolver is scoped to `lab.supermorphic.com`, the hostname answer is
`192.168.90.30`, the route uses Tailscale, and HTTPS has no certificate warning.

Then disconnect Tailscale while still off-LAN. Confirm those private names are no longer
usable. Public Internet access must not be a fallback.

## Accept the path from an iPhone

1. Turn Wi-Fi off so the phone uses cellular.
2. Open Tailscale and confirm it is connected to the intended tailnet.
3. Open `https://homepage.lab.supermorphic.com` in Safari.
4. From Homepage, open representative applications such as Grafana, Portainer, Seerr,
   and ntfy.
5. Confirm there is no certificate warning and each application authenticates normally.
6. Disconnect Tailscale while remaining on cellular and confirm the lab applications
   become unreachable.

The repository does not pin the iOS client version, so rely on current connection and
DNS status rather than historical navigation labels.

## Check overlapping routing on the home LAN

With Tailscale connected on the home LAN, inspect the routes and repeat DNS plus HTTPS
acceptance. A `/32` is more specific than the local LAN `/24`; normal longest-prefix
selection can therefore send these two addresses through Tailscale even while the client
is physically on that LAN.

Confirm the actual route instead of assuming it. If the `/32` uses Tailscale, access to
Pi-hole and the Gateway depends on at least one healthy Connector replica while Tailscale
remains connected. Tailscale documents longest-prefix behavior for
[overlapping subnet routes](https://tailscale.com/docs/reference/troubleshooting/network-configuration/overlapping-subnet-route-failover).

## Maintenance

### Replace the DNS resolver

1. Deploy and validate the new resolver outside this procedure.
2. Add its exact `/32` to the Connector, `autoApprovers.routes`, and DNS grant.
3. Validate and publish the Git change.
4. Confirm both Connector devices advertise and receive approval for the new route.
5. Add the new restricted nameserver and test real clients.
6. Remove the old nameserver, route, auto-approval, and grant only after no client
   depends on them.

Do not replace the old route first. The additive transition preserves name resolution
during migration.

### Change the Gateway VIP

1. Add the new exact `/32` and HTTPS grant to external policy.
2. Update the Connector source and authoritative internal DNS through their owning Git
   workflows.
3. Validate, publish, and let Flux reconcile.
4. Confirm both Connector devices carry the new route.
5. Complete off-LAN DNS and HTTPS acceptance.
6. Remove the old route and grant after migration succeeds.

### Add another tailnet user

Do not admit another user while the grants use `autogroup:member`. Define a reviewed
group, change both lab-domain grants to that group, save and verify the policy, and only
then add the user.

## Troubleshooting order

1. **Client connection:** Is Tailscale connected to the intended tailnet?
2. **Route approval:** Do both `lab-subnet-router-*` devices show both exact routes
   approved, with no broad route?
3. **Split DNS:** Is `192.168.90.2` configured as a restricted nameserver for exactly
   `lab.supermorphic.com`?
4. **DNS answer:** Does Pi-hole return `192.168.90.30` for the application hostname?
5. **Gateway:** Does HTTPS reach the Gateway on port `443` with a valid certificate?
6. **Kubernetes routing:** Are the internal Gateway and the application's HTTPRoute and
   backend healthy?
7. **One application only:** If other applications work, inspect that application's
   route, host handling, and authentication rather than changing Tailscale.

If one Connector Pod is Pending, inspect node availability. The ProxyClass deliberately
uses `DoNotSchedule` so two replicas do not silently co-locate and defeat node-level
failover.
