# Recover Plex remote playback with Relay

## Trigger

Use this runbook when Plex direct remote access is unavailable or intentionally disabled
and an authorized off-site client should fall back to Plex Relay.

Relay is a limited fallback, not the normal production path. Configure, accept, change,
or disable direct access with
[Operate Plex direct remote access](../guides/plex-remote-access-operations.md).

```text
direct path unavailable
        ↓
authorized client requests the server
        ↓
did Plex start Relay?
        ↓
did Relay authenticate and allocate a port?
        ↓
can the client browse and play?
        ↓
verify Relay use and local Plex health
```

Plex currently limits Relay streams to 2 Mbps. Higher-bitrate media may require
transcoding, downloads cannot use Relay, and not every Plex client supports Relay. See
[Plex's Relay documentation](https://support.plex.tv/articles/216766168-accessing-a-server-through-relay/).

## Immediate safety

Relay is outbound-only in this deployment: Plex connects to the Relay service over TCP
`443`, and the local Relay child forwards to Plex on pod loopback port `32401`.

Do not recover Relay by:

- adding another public port or inbound Kubernetes listener;
- enabling UPnP or NAT-PMP;
- adding an unauthenticated Plex network;
- mounting or replacing raw Relay credentials;
- widening Cilium or router policy; or
- exposing loopback port `32401`.

Keep Plex tokens, account identifiers, email addresses, client addresses, and raw logs
out of repository artifacts.

## Authority

| Operation | Effect and authority |
| --- | --- |
| `mise exec -- just kube plex-verify` | Approved scoped live verification; it observes the deployed Plex contract but does not test Relay |
| `mise exec -- just kube plex-relay-status` | Operator-only live diagnostic; it uses the diagnostic context to inspect sanitized runtime and Relay log state without creating a Relay session |
| Plex account or Relay-setting change | Operator-managed application-state mutation |
| UniFi mapping change | Operator-managed router mutation through the direct-access operations workflow |
| Workload or network-policy change | Reviewed Git change; persistent Flux-managed state is not patched live |

A confirmation string is an execution guard. It does not change who owns an operation.

## Diagnose

### 1. Confirm Plex itself is healthy

Run:

```bash
mise exec -- just kube plex-verify
```

If it fails, stop treating the incident as Relay-only. Repair the reported Plex,
storage, Service, route, DNS, or TLS boundary before testing fallback.

Confirm local authenticated browse and playback still work. Relay cannot compensate for
an unavailable server or library.

### 2. Confirm fallback is eligible

In the Plex server settings, confirm:

- Remote Access has not been explicitly disabled, even if its direct connection is
  unavailable;
- **Enable Relay** remains enabled;
- **Secure connections** remains **Preferred** or **Required**; and
- the off-site client is signed into an authorized Plex account with library access.

Do not add an unauthenticated network to work around account or client discovery.

### 3. Observe the Relay lifecycle

Start a browse or playback request from the affected off-site client. During that
attempt, run:

```bash
mise exec -- just kube plex-relay-status
```

The command reports Plex's runtime identity, Relay key-cache readability, secure-
connection eligibility, and sanitized lifecycle lines containing `startRelay`,
authentication, port allocation, or child exit. It does not start Relay and does not
prove that a client used an allocated tunnel.

Use the result to narrow the incident:

| Evidence | Investigate next |
| --- | --- |
| No `startRelay` or `Relay: starting relay` line during the request | Plex cloud discovery, Remote Access and Relay settings, client sign-in, and account/library authorization |
| Relay child exits before authentication | Plex runtime identity, native Relay cache, and Plex process health; do not replace the cache with a raw key |
| Authentication appears but no `Allocated port` line follows | Plex Relay service availability and Plex's allowed outbound TCP `443` path |
| A port is allocated but the client cannot browse | Client Relay support, account authorization, library access, and stale client discovery |
| Browse works but playback fails | The 2 Mbps ceiling, required transcoding capacity, client support, and media compatibility |

An allocated port proves that the server-side Relay child established its side of the
tunnel. It does not by itself prove client browse or playback.

## Recover or mitigate

Apply only the action identified by the evidence:

- Correct the affected client's sign-in or library authorization, then force the client
  to rediscover the server.
- Restore **Enable Relay** or an eligible secure-connection setting through Plex's
  supported UI if it drifted.
- If the Relay child cannot authenticate, preserve the native cache and inspect Plex
  process and retained-config health. Do not inject credentials.
- If authentication succeeds but allocation does not, verify ordinary public HTTPS
  egress and Plex service status. Do not create inbound exposure.
- If only playback fails, choose Relay-compatible media or allow Plex to transcode below
  the Relay ceiling. Do not classify the ceiling as a network-policy failure.

### Intentional Relay acceptance

Do not remove the direct DNAT during ordinary fallback recovery; the direct path is
already unavailable in that incident.

If the operator deliberately needs to prove Relay independently, use an attended window
and the disablement procedure in
[Operate Plex direct remote access](../guides/plex-remote-access-operations.md#disable-or-roll-back-exposure)
to remove the single DNAT temporarily. Then disable Wi-Fi and Tailscale on the test
client, force client rediscovery, and repeat the diagnostics above. Restore the direct
path only through the same operations guide.

## Verify recovery

Require all of the following:

- `plex-relay-status` shows the expected Relay authentication and port allocation;
- the authorized off-site client can browse and play;
- Plex or client activity identifies the connection as Relay or indirect rather than
  direct;
- local Plex browse and playback remain healthy; and
- `mise exec -- just kube plex-verify` still passes.

Do not use Relay success as evidence for direct WAN access, Sonos account linking,
Plexamp player discovery, or speaker reachability.

## Escalate

Stop rather than increase exposure or privilege when:

- the Relay child repeatedly exits;
- required outbound connectivity is unavailable;
- `plex-verify` fails;
- runtime identity or retained Plex state appears damaged;
- credentials would need replacement;
- workload or Cilium policy would need widening; or
- the only apparent recovery adds a public listener.

Use the Plex recovery path in
[Recover Longhorn and application state](platform-disaster-recovery.md#recover-longhorn-and-application-state)
when retained configuration or storage is suspect. Durable workload or policy changes
need a reviewed design and Git change.
