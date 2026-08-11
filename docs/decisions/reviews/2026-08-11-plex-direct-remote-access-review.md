# Spec Review

**Spec:** /Users/ksiggins/Development/homelab-talos.investigate-plex-remote-access/docs/decisions/2026-08-11-plex-direct-remote-access.md  
**Reviewer:** GPT-5.6-sol / Codex  
**Verdict:** Not ready — the specified Plex settings can regress local discovery, the stage-2 gate contradicts measured evidence, and rollback does not terminate established exposure

## Findings

### F1 — Defect
**Where:** §1 Decision, §5.1 Local horizon, and §6 Plex settings  
**Mechanism:** the custom server access URL remains `https://plex.lab.supermorphic.com/` without an explicit port while the Remote Access public port is changed to `32400`  
**Failure:** Plex documents that a custom access URL without a port automatically uses the port from Remote Access. Plex will therefore publish `https://plex.lab.supermorphic.com:32400`, but repository DNS resolves that name to the internal Envoy VIP and the internal Gateway listens only on `443`. Rediscovering local clients that follow the published custom connection will attempt the VIP on `32400`, bypassing the only specified local listener and regressing the hard local-playback rows. [Plex Network settings](https://support.plex.tv/articles/200430283-network/)  
**When:** stage 2 sets the manual public port to `32400` and a local client refreshes its server-discovery information

### F2 — Contradiction
**Where:** §3 Evidence and §7 Staging and gates  
**§3 says:** Plex remained `Mapped - Not Published (Not Reachable)` while Sonos played, so reachability state “is therefore not the discriminator”  
**§7 says:** leaving `Not Published (Not Reachable)` is the mandatory stage-2 gate, “the first honest signal,” and a precondition for Plex constructing the media URL  
**Why both cannot hold:** a state observed during successful Sonos playback cannot simultaneously be a universal precondition for constructing the media URL that enabled that playback. As written, the same unchanged state is both declared non-discriminating and used to block the experiment before its actual playback discriminator is tested.

### F3 — Defect
**Where:** §8 Rollback and §11 Decision record  
**Mechanism:** deleting the UniFi DNAT is declared sufficient on its own to end exposure and constitute complete rollback  
**Failure:** deleting a forwarding rule blocks new connections but does not necessarily remove established NAT/conntrack sessions. The existing repository runbook explicitly records this behavior and follows DNAT deletion with a guarded public-Envoy connection flush. Under the stated rollback, an established direct session to Plex can continue after the supposedly complete rollback.  
**When:** any connection to Plex is established when the DNAT is deleted and UniFi retains its conntrack entry

### F4 — Defect
**Where:** §7 Stage 4  
**Mechanism:** the public Gateway, exporter, Cloudflare A record, UniFi DDNS entry, and scoped token are said to be removed “each through a reviewed Git revert rather than a live edit”  
**Failure:** Git reconciliation manages the Gateway and exporter, but the repository’s accepted amendment and runbook establish that the operator created the Cloudflare record, UniFi DDNS entry, and token directly in those external systems. A Git revert cannot delete, disable, or revoke them, so the explicitly required teardown remains incomplete.  
**When:** stage 3 passes and stage 4 is executed using only the specified Git-revert mechanism

## Grounding

- **Assumption:** the reviewed artifact is the identified spec.  
  **Checked:** SHA-256 of the complete file.  
  **Found:** `3809e775bd89777f7de25b11707d899852ad02615cf5b9b5a74bbf492321d205`, matching the supplied prefix.

- **Assumption:** retaining the portless custom URL preserves the internal `443` path after manual Remote Access port `32400` is enabled.  
  **Checked:** `kubernetes/apps/media/plex/app/httproute.yaml`, `kubernetes/apps/networking/internal-gateway/app/gateway.yaml`, and Plex’s current official Network settings documentation.  
  **Found:** the internal route attaches only to the Gateway’s `443` listener, while Plex documents that an omitted custom-URL port inherits the Remote Access port. This grounds F1.

- **Assumption:** the required combination of a retained custom connection and direct `32400` publication causes Sonos to select the new `plex.direct` connection.  
  **Checked:** the spec’s measurement table and current Plex documentation for custom URLs, Remote Access, secure connections, and Sonos.  
  **Found:** **UNVERIFIED.** The measured states do not include that combination. Plex documents that custom URLs are published to plex.tv, but does not document client-specific connection precedence establishing that Sonos will prefer the native direct connection.

- **Assumption:** the existing internal MetalLB pool can supply `.31` explicitly without creating another pool.  
  **Checked:** `kubernetes/apps/networking/metallb/config/address-pool.yaml`, its README, and repository-wide address references.  
  **Found:** `.31` is inside the `.30–.38` `autoAssign: false` pool and no other repository manifest requests it. The README records `.30–.39` as excluded from DHCP. Current external UniFi assignment or address use is **UNVERIFIED**.

- **Assumption:** the current Cilium policy requires a new `world:32400` ingress allowance for preserved external source addresses.  
  **Checked:** `kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml` and `scripts/validate/plex.sh`.  
  **Found:** the current policy admits `host` and `remote-node` on `32400`, explicitly rejects `world`, and admits no other ingress port. The proposed policy edit is therefore grounded in current source.

- **Assumption:** removing the DNAT alone terminates established exposure.  
  **Checked:** `docs/runbooks/plex-relay-sonos.md` and the `plex-public-connection-flush` guarded recipe in `kubernetes/mod.just`.  
  **Found:** the runbook explicitly says DNAT deletion might not terminate established conntrack sessions and requires a connection flush afterward. This grounds F3.

- **Assumption:** all stage-4 teardown targets can be removed through Git.  
  **Checked:** the public Gateway and DDNS-exporter Flux Kustomizations, the superseded amendment, and `docs/runbooks/plex-relay-sonos.md`.  
  **Found:** the cluster resources are Git-managed, but the Cloudflare record, UniFi DDNS entry, and scoped token are explicitly operator-managed external state. This grounds F4.

- **Assumption:** the containment capture’s zero-ingress inference can be explained by Relay terminating on pod loopback `127.0.0.1:32401`.  
  **Checked:** the accepted 2026-08-02 design, `scripts/diagnose/plex-relay-status.sh`, and the current Cilium policy.  
  **Found:** the accepted evidence records Relay allocation to `127.0.0.1:32401`, and the diagnostic recognizes Relay allocation logs. A new live Relay trace was not collected, so current runtime confirmation is **UNVERIFIED**.
