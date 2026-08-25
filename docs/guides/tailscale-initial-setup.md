# Set up Tailscale for the homelab

Use this guide for first-time Tailscale onboarding. It explains the order in which to
prepare the tailnet, operator devices, Kubernetes integration, and private services. The
detailed configuration belongs to the subsystem guides linked from each step.

## Setup model

```text
tailnet account + operator clients
              ↓
reviewed base access policy
              ↓
Kubernetes Operator + HA ProxyGroup
              ↓
first private service
              ↓
optional same-URL lab-domain access
              ↓
off-LAN client acceptance
```

A **tailnet** is the private network formed by the devices signed in to one Tailscale
account or organization. The Kubernetes Operator connects selected cluster resources to
that network. It does not make the cluster public and it is not an exit node in this
deployment.

## Who owns each part

| Part | Owning documentation |
| --- | --- |
| First-time ordering and completion | This guide |
| Operator, OAuth client, `tag:k8s-operator`, `tag:k8s`, and shared ProxyGroup | [Tailscale Operator operations](tailscale-operator-operations.md) |
| ntfy's `tag:ntfy`, Tailscale Service policy, and phone setup | [ntfy operations](ntfy-operations.md) |
| Connector, `tag:lab-router`, exact routes, split DNS, and same-URL client tests | [Lab-domain access over Tailscale](tailscale-lab-domain-access.md) |

The tailnet policy is external operator-managed state in the Tailscale Admin Console. It
is not stored as an executable policy file in this repository. Each owning guide records
only the policy fragment required by its feature. Do not assemble a new policy by blindly
replacing the current one with copied fragments; merge and review the required
relationships in **Access controls**.

## 1. Create or select the tailnet

Sign in to Tailscale with the operator's identity provider. Confirm that this is the
tailnet intended for the homelab before adding devices, tags, or credentials.

The Kubernetes Operator is available on current Tailscale plans. Plan availability can
change, so use the [current Tailscale Operator documentation](https://tailscale.com/docs/kubernetes-operator)
instead of treating this guide as a plan entitlement reference.

## 2. Install the operator clients

Install Tailscale on the Mac and iPhone that will perform acceptance testing. Sign both
devices in to the same tailnet and confirm that Tailscale reports them as connected.

Do not select an exit node for this design. Normal Internet traffic continues to use the
device's ordinary Wi-Fi or cellular path. Tailscale carries only traffic for its private
devices, Services, and approved subnet routes.

Installing clients first gives the operator a real off-LAN device for later acceptance.
Kubernetes readiness alone cannot prove that a phone or Mac can use the resulting path.

## 3. Establish the base access posture

Open **Access controls** in the Tailscale Admin Console. Review the current policy before
changing it.

- Do not retain an unrestricted allow-all rule as the long-term homelab policy.
- Do not enable Tailscale SSH unless a separate reviewed design requires it.
- Add the Operator tag ownership from the
  [Operator operations guide](tailscale-operator-operations.md) first.
- Add service and subnet-route permissions only from the guide that owns that feature.

The current policy uses `autogroup:member` only because the tailnet has one human user.
Before adding another user, replace those source selectors with a reviewed group whose
membership matches the intended access. Do this before inviting or admitting the new
user, not afterward.

## 4. Prepare the Kubernetes Operator

Follow [Tailscale Operator operations](tailscale-operator-operations.md) to:

1. create `tag:k8s-operator` and `tag:k8s` ownership;
2. create the scoped OAuth client in **Trust credentials**;
3. write its ciphertext through the guarded SOPS workflow;
4. publish the source through the normal pull-request path;
5. use the guarded bootstrap only for a deliberately suspended fresh deployment; and
6. run source and scoped live verification.

The repository deploys one Operator and a shared two-replica ingress `ProxyGroup` named
`ingress-proxies`. Do not install a second copy manually with Helm.

## 5. Enable private HTTPS service prerequisites

Before deploying a Tailscale `Ingress` such as ntfy:

1. Open **DNS** in the Admin Console.
2. Confirm **MagicDNS** is enabled.
3. Under **HTTPS Certificates**, enable HTTPS and acknowledge the Certificate
   Transparency disclosure.

Tailscale-issued certificate names appear in public Certificate Transparency logs. That
publishes the certificate name, not network reachability. Keep service names free of
sensitive information and use placeholders such as `ntfy.<tailnet>.ts.net` in this public
repository. See Tailscale's current [HTTPS certificate documentation](https://tailscale.com/docs/how-to/set-up-https-certificates).

## 6. Configure the first private service

Use [ntfy operations](ntfy-operations.md) for the first private service integration. That
guide owns:

- the `tag:ntfy` tag and service auto-approval relationship;
- the ntfy `Ingress` that uses `ingress-proxies`;
- the canonical `https://ntfy.<tailnet>.ts.net` client URL; and
- real phone delivery acceptance.

This real application acceptance proves the shared path:

```text
tailnet client
      ↓
Tailscale Service
      ↓
ingress-proxies
      ↓
Kubernetes Service
```

There is no repository-owned throwaway ProxyGroup compatibility test. Do not create an
ad-hoc test `Ingress` merely because an older walkthrough instructed it.

## 7. Add same-URL lab-domain access when wanted

The optional lab-domain design uses a different path from a ProxyGroup-backed Tailscale
Service. Follow [Lab-domain access over Tailscale](tailscale-lab-domain-access.md) to
configure the Connector, exact `/32` routes, restricted nameserver, and client tests.

```text
ProxyGroup service                 Lab-domain Connector
ntfy.<tailnet>.ts.net              app.lab.supermorphic.com
        ↓                                   ↓
Tailscale Service                  split DNS + two /32 routes
        ↓                                   ↓
shared ingress proxies             existing internal Gateway
```

## 8. Complete off-LAN acceptance

First-time setup is complete when all of the following are true:

- the Mac and iPhone are connected to the intended tailnet;
- the unrestricted default access policy is no longer the operating policy;
- `tag:k8s-operator` owns the required Operator-managed tags;
- the Operator and both `ingress-proxies` replicas pass repository verification;
- the first app-specific Tailscale Service appears in the Admin Console and is usable
  from an authorized off-LAN client;
- the same client cannot reach that private service after disconnecting Tailscale; and
- before any second human user joins, `autogroup:member` has been replaced with a
  reviewed group.

Client acceptance is a human check. Repository verifiers confirm Kubernetes structure
and runtime health, but they cannot prove the external tailnet policy, client routing,
certificate presentation, or application login experience.
