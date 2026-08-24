# Operate Plex direct remote access

Use this guide to establish, operate, validate, change, or remove Plex's production
direct remote-access path. This path exposes Plex Media Server to the Internet and
requires an attended operator window when it changes.

[Specification 013](../specs/013-plex-direct-remote-access.md) records the completed
design and accepted result. Current repository policy, source, and this operating guide
describe what to do now.

## Production path

Plex publishes its own TLS endpoint through one explicit IPv4 router mapping:

```text
off-site Plex client
        ↓
WAN-derived *.plex.direct:32400
        ↓
residential WAN IPv4
        ↓
one UniFi TCP port forward
        ↓
Plex LoadBalancer:32400
        ↓
Plex Media Server
```

Local browser and application traffic normally uses a different path:

```text
local Plex client
        ↓
plex.lab.supermorphic.com
        ↓
internal Envoy Gateway
        ↓
Plex Service:32400
```

The direct LoadBalancer path is also used for the private `plex.direct` discovery URL and
the Sonos VLAN. The internal Envoy hostname must not be advertised as Plex's custom
server URL; the accepted Sonos path needs the LoadBalancer-derived `plex.direct` name.

## Ownership boundary

Git owns:

- the Plex workload and retained configuration volume;
- the LoadBalancer Service and internal HTTPRoute;
- the Cilium ingress and egress policy;
- the Hubble metric configuration and Plex alert rules; and
- the verifier, packet-enforcement test, and bounded observation workflow.

Operator-managed systems outside Git own:

- the single UniFi port forward;
- Plex Remote Access, Network, account, and client settings;
- Pi-hole handling of private `plex.direct` answers;
- the Sonos VLAN route to the Plex LoadBalancer; and
- the absence of unintended public IPv6 exposure.

Git can prove its desired source state. It cannot prove that those external systems still
match the design. Treat their checks as separate operator acceptance.

## When operator action is needed

| Situation | Action |
| --- | --- |
| Normal operation | No configuration change; use normal health and alert monitoring |
| Restore or enable direct access | Validate the Kubernetes side, then configure Plex and the single UniFi mapping |
| Change the Service, route, workload, or Cilium policy | Make a reviewed Git change, reconcile it, then verify live state |
| Change Plex, UniFi, Pi-hole, Sonos, or IPv6 settings | Use an attended operator window and repeat affected acceptance checks |
| Prove packet enforcement | Run the guarded Plex network-policy test in an approved window |
| Prove the detection pipeline | Use the separate [Plex remote-access detection test](plex-remote-access-detection-test.md) |
| Disable public exposure | Remove the UniFi mapping and prove new off-site connections fail |
| Suspected incident | Remove exposure, preserve private evidence, and follow the response runbook |

## Command effects and authority

| Command or operation | What it does | Effect and authority |
| --- | --- | --- |
| `mise exec -- just kube plex-validate` | Validates the declarative Plex listener, workload, storage, and policy contract | Local, read-only, shared validation |
| `mise exec -- just kube plex-verify` | Checks deployed readiness, runtime hardening, Service, route, DNS, and internal TLS | Approved diagnostic verifier; agent-autonomous when scoped verification is needed |
| Service, EndpointSlice, and Cilium policy reads | Inspect live API objects outside the verifier's assertions | Read-only observation with an approved credential |
| `mise exec -- just kube plex-network-policy-test` | Creates two run-scoped probe Pods, tests enforced traffic behavior, then removes them | Operator-run, state-changing integration test |
| `mise exec -- just kube plex-network-observe` | Opens a bounded Hubble port-forward and prints live Plex L3/L4 flows | Operator-only read diagnostic; output can contain private addresses |
| Plex or UniFi UI changes | Change application, account, or router state outside Git | Operator mutation |

A confirmation variable is an execution guard. It does not by itself determine who owns
an operation.

## Normal operation

No recurring manual action is required while direct access, local playback, and detector
health remain normal. Monitor Plex, Gatus, Prometheus, Alertmanager, and ntfy. Use the
[detection response runbook](../runbooks/plex-remote-access-detection.md) when a Plex
remote-access rule fires or its telemetry is missing.

Plex's Remote Access status is useful context, but it is not a routing oracle. Actual
client paths, Tautulli classification, live Kubernetes state, and off-network checks are
the acceptance evidence.

## Validate the Kubernetes listener and policy

Run source validation first:

```bash
mise exec -- just kube plex-validate
```

It requires, among other Plex invariants:

- one `LoadBalancer` application port, TCP `32400`;
- the explicit MetalLB address from the non-auto-assigned internal pool;
- `externalTrafficPolicy: Local` to preserve off-cluster source identity;
- `allocateLoadBalancerNodePorts: false` and a rendered null NodePort field;
- an internal HTTPRoute with its long-response timeout disabled; and
- one `world` Cilium ingress rule limited to TCP `32400`.

After the merged source has reconciled, run live verification:

```bash
mise exec -- just kube plex-verify
```

### What `plex-verify` proves

- the Plex Kustomization and HelmRelease are Ready;
- the Deployment rollout is complete;
- Plex runs as UID `568`, has no Kubernetes API token, mounts media read-only, and can
  write its configuration;
- the Service is a LoadBalancer with the expected address and source-preserving policy;
- LoadBalancer NodePort allocation is disabled and no NodePort remains allocated;
- the internal HTTPRoute is accepted;
- internal DNS resolves to the Gateway; and
- `/identity` is reachable through internal TLS.

### What `plex-verify` does not prove

It does not prove:

- ready EndpointSlice state or the live application-port value;
- the exact applied CiliumNetworkPolicy;
- packet-level ingress or egress enforcement;
- the UniFi mapping or real WAN reachability;
- the absence of a public IPv6 path;
- Plex's LAN-versus-WAN classification;
- Sonos or other native-client behavior; or
- Plex alert evaluation and notification delivery.

Inspect the live objects when changing the production listener or policy:

```bash
mise exec -- kubectl --kubeconfig .kube/config --namespace media \
  get service plex --output yaml
mise exec -- kubectl --kubeconfig .kube/config --namespace media \
  get endpointslice --selector kubernetes.io/service-name=plex --output yaml
mise exec -- kubectl --kubeconfig .kube/config --namespace media \
  get ciliumnetworkpolicy plex --output yaml
```

Require exactly one Service application port, TCP `32400`, without a NodePort. Require at
least one ready EndpointSlice endpoint on TCP `32400`. Require the applied policy to
select Plex and contain exactly one `world` ingress rule, also limited to TCP `32400`.

These reads prove API object state, not traffic enforcement. The independent packet
oracle creates two run-owned probe Pods and removes them after the test:

```bash
PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' \
  mise exec -- just kube plex-network-policy-test
```

Run it only in an approved operator window. It proves selected Plex-policy egress is
denied to the tested API, ntfy, and gateway targets; an unrelated Pod cannot reach Plex;
the normal Plex verifier still passes; and the probes are removed. It does not prove the
external router boundary.

## Check router and automatic-mapping safety

Before enabling or changing exposure:

1. Inventory the current UniFi mappings. There must be no second Plex or TCP `32400`
   rule.
2. Confirm UPnP and NAT-PMP remain disabled. Plex must not be able to create an
   independent automatic mapping.
3. Confirm UniFi Intrusion Prevention remains in **Notify and Block** mode for the
   Servers network, with the intended detections and no unintended exclusion.
4. Confirm the gateway owns a real public IPv4 path rather than an unaccounted-for
   upstream NAT boundary.
5. Review IPv6 separately. An IPv4 port-forward configuration says nothing about
   unsolicited inbound IPv6.

Current UniFi releases move port-forward controls between **Policy Engine** and
**Policy Table**. Follow the installed version's Port Forwarding view; the durable
contract is one TCP mapping, not a particular menu location.

## Check Plex account and application safety

Record current runtime settings privately before changing them. Do not put the WAN
address, Plex token, account identity, `plex.direct` certificate identifier, or client
address in repository artifacts.

The intended operator-managed settings are:

| Plex control | Intended state |
| --- | --- |
| Remote Access | Enabled |
| Manually specify public port | Enabled with `32400` |
| Authentication | Enabled |
| List of addresses and networks allowed without auth | Empty |
| Account multi-factor authentication | Enabled |
| Remote streams allowed per user | `2` |
| Client network | IPv4 only |
| Enable Relay | Enabled as fallback |
| Custom server access URLs | Only the private LoadBalancer-derived `plex.direct` URL, including port `32400` |
| LAN Networks | Trusted client VLANs and `10.244.0.0/16`; exclude `192.168.90.0/24` |
| Empty trash automatically after every scan | Disabled |

Changing **Secure connections** is outside specification 013. Keep its existing approved
value. Plex's current advanced Network settings still use **LAN Networks**, **Custom
server access URLs**, **Enable Relay**, and **List of IP addresses and networks that are
allowed without auth**; menu placement can change across Plex releases.

The custom server URL has this form:

```text
https://<load-balancer-address-with-dashes>.<certificate-id>.plex.direct:32400
```

It is a private discovery path to the LoadBalancer. Do not advertise
`plex.lab.supermorphic.com` in this setting. Pi-hole must permit the private address
embedded in the `plex.direct` answer instead of stripping it as DNS rebinding.

## Prove LAN classification before relying on remote limits

Start local playback through `plex.lab.supermorphic.com`. In Tautulli's current activity
view, require the session to show **LAN**, not **WAN**.

The internal Envoy route hides the original client behind an Envoy Pod address. Plex's
**LAN Networks** therefore includes trusted client VLANs and the Pod CIDR
`10.244.0.0/16`. It deliberately excludes the cluster VLAN `192.168.90.0/24` so a future
node source-NAT path cannot incorrectly exempt an Internet session from remote limits.

If local playback shows **WAN**, stop. Correct the intended Plex setting and repeat this
acceptance before treating the per-user remote-stream limit as effective.

## Create or restore the direct path

1. Complete the Kubernetes validation and live object checks above.
2. Confirm detector readiness. Do not establish Internet exposure while the remote-access
   telemetry is known to be blind.
3. In Plex, set the private LoadBalancer-derived custom server URL, including TCP
   `32400`.
4. In UniFi, create exactly one port forward:

   | Field | Value |
   | --- | --- |
   | Protocol | TCP |
   | External port | `32400` |
   | Forward address | Plex LoadBalancer address |
   | Internal port | `32400` |
   | Logging | Enabled when the installed version exposes it |

5. In Plex Remote Access, enable **Manually specify public port**, enter `32400`, then
   apply or retry the connection.
6. Do not add another public hostname, IPv6 route, WAN port, UDP mapping, range,
   reverse proxy, tunnel, or automatic mapping.
7. Confirm Plex publishes a WAN-derived `*.plex.direct:32400` connection. Treat the
   green Remote Access indicator as supporting context, not sufficient proof.

The Sonos VLAN needs an operator-managed route to the Plex LoadBalancer on TCP `32400`.
Do not point it at the internal Gateway or a retired Plex host.

## Accept the normal remote path

Force client rediscovery before each affected test. Require these human-visible results:

- local playback remains **LAN** in Tautulli;
- Apple TV, Plex iOS, and local Plexamp playback remain healthy;
- Plexamp switches to Sonos and plays without AirPlay;
- native Sonos browses and plays the Plex library;
- Tautulli records sessions and Homepage and Gatus remain healthy;
- an off-site cellular client connects directly rather than through Relay; and
- the client's displayed server connection matches the intended direct path.

From a genuinely off-network client, confirm exactly one reviewed TCP exposure. A LAN
scan is not evidence about the WAN boundary. Verify IPv6 independently by checking
delegated prefixes, global node addresses, public DNS answers, UniFi unsolicited-inbound
policy, and an actual off-network IPv6 connection attempt. An absent AAAA record alone
does not prove there is no IPv6 path.

This is normal path acceptance. Do not generate synthetic attack traffic here. To prove
the Hubble → Prometheus → Alertmanager → ntfy detector, use the separate
[attended detection test](plex-remote-access-detection-test.md).

## Observe or respond to suspicious traffic

The bounded Hubble diagnostic can print live Plex flows for at most 600 seconds:

```bash
mise exec -- just kube plex-network-observe 600
```

It opens a local Hubble port-forward and prints L3/L4 flow data. It does not mutate the
cluster, but its output can include private source addresses. Run it only as an attended
operator diagnostic and keep raw output out of commits, pull requests, and published test
artifacts.

Follow [Respond to Plex remote-access alerts](../runbooks/plex-remote-access-detection.md)
for diagnosis and containment.

## Disable or roll back exposure

1. Remove the single UniFi port forward. This blocks new inbound connections.
2. Clear Plex's manually specified public port if direct access will remain disabled.
3. From an off-network client, prove a new TCP `32400` connection cannot be opened.
4. Confirm local playback, Tautulli, Homepage, and Gatus still work.

Removing the port forward does not guarantee eviction of an established conntrack entry
or Plex session. If active abuse or suspected compromise requires session eviction, use
an authorized operator workflow to restart Plex. The restart interrupts all clients
because Plex is a single `Recreate` Deployment using a `ReadWriteOncePod` configuration
claim.

Do not remove workload hardening, the read-only media mount, bounded egress, detection,
or Relay fallback merely because public exposure is disabled. Durable Kubernetes changes
still go through reviewed Git.

## Recovery readiness

Before changing production exposure, confirm scheduled Plex database backups and the
off-cluster Longhorn configuration backup are healthy. Require current evidence that the
configuration restore has been rehearsed with a throwaway claim and isolated Plex
validation as described in
[Recover Longhorn and application state](../runbooks/recovery.md#recover-longhorn-and-application-state).

Bulk media has no independent backup. Recovery after total media loss depends on
reacquisition. Plex's media mount remains read-only, and **Empty trash automatically after
every scan** remains disabled so a temporary storage outage does not discard library
entries.

## Review boundary

Review the production design after a material change to the gateway mapping, public DNS,
address families, Plex network or account settings, Service listener, Cilium policy,
notification route, or recovery design. For Relay or Sonos-specific failure handling,
use [Recover Plex Relay or Sonos playback](../runbooks/plex-relay-sonos.md).
