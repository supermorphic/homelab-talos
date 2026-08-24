# qbit_manage seeding policy

`qbit_manage` applies the declarative torrent-seeding policy in
[`config.yml`](../../kubernetes/apps/media/qbit-manage/app/config.yml). It runs without a
UI in the `media` namespace and talks to qBittorrent through its internal Service. It
does not join Gluetun's network namespace, expose a Service or HTTPRoute, or mount the
organized `/data/media` library.

The SOPS-encrypted `qbit-manage-secret` supplies the qBittorrent Web UI credential as
`QBT_USER` and `QBT_PASS`. The password manager remains the human source for the same
credential used by the media applications.
Use the [qbit_manage operations guide](../guides/qbit-manage-operations.md) to create that
ciphertext and perform a guarded bootstrap.

## Classification contract

The policy manages torrents in the exact `tv`, `movies`, and `music` categories. A
torrent matches one share-limit group; lower numeric priority wins.

Two independent mechanisms protect private torrents:

- `settings.private_tag` applies `tracker-private` to every torrent whose metadata marks
  it private; and
- the `tracker` map adds tracker-specific tags for known announce hosts.

The generic tag is the primary safety net. A private torrent remains excluded from
cleanup even when its announce host is not yet mapped. The tracker map is required only
when a tracker needs a specific tag or share-limit group.

```text
tracker-czteam + any category ───────► czteam (priority 10)
music without private tags ─────────► music (priority 50)
tv/movies without private tags ─────► public (priority 100)
```

The current groups are:

| Group | Selection | Minimum | Ratio | Maximum | Action | Cleanup |
| --- | --- | ---: | ---: | ---: | --- | --- |
| `czteam` | `tracker-czteam` | 7 days | 2.0 | Unlimited | `Stop` | Disabled |
| `music` | category `music`, no private tag | 7 days | 2.0 | 30 days | `Stop` | Enabled |
| `public` | category `tv` or `movies`, no private tag | 1 day | 1.5 | 7 days | `Stop` | Enabled |

For `czteam`, both the minimum time and ratio must be satisfied. A torrent below ratio
2.0 has no finite time limit. See [CZTeam private-tracker policy](qbit-manage-czteam.md)
for the tracker-specific contract and acceptance procedure.

The public and music maximum times are unconditional. Cleanup moves only the
download-side name into `/data/downloads/.RecycleBin`; the recycle bin retains it for
seven days. The organized library name remains because the imported file is a hardlink
on the same SMB filesystem.
Use the [recovery runbook](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean)
before the seven-day window expires when cleanup targets the wrong torrent.

## Ownership boundaries

- Sonarr, Radarr, and Lidarr own the `tv`, `movies`, and `music` categories, imports,
  renames, and organized library files.
- qBittorrent downloads and seeds.
- qbit_manage owns successful-torrent ratio, seed time, stop action, and final cleanup.
- qbit_manage mounts only `/data/downloads` and cannot modify `/data/media`.
- qBittorrent's global ratio and seed-time limits remain disabled so they cannot stop a
  private torrent before its selected policy allows it.

`share_limit_action: Stop` is reversible. The configuration disables removal of
unregistered torrents, orphan removal, no-hardlink handling, and tracker-error deletion.

## Safety invariants

`scripts/validate/qbit-manage.sh` and `scripts/validate/qbit-manage-policy.sh` enforce
these invariants in `mise exec -- just ci`:

- category updates are disabled;
- `czteam` has the unique highest precedence;
- every cleanup-enabled group excludes `tracker-private` and `tracker-czteam`;
- every group priority is unique;
- known private hosts map to `tracker-private`, never `tracker-public`;
- the `czteam` group uses `Stop`, has no finite maximum time, and never cleans up;
- `settings.private_tag` is `tracker-private`;
- destructive removal features remain disabled;
- credentials come only from the SOPS Secret through `!ENV`; and
- the workload never mounts `/data/media`.

## Adding a private tracker

Never copy a full announce URL. It can contain a passkey. Use only the bare announce
hostname shown in qBittorrent.

The generic `tracker-private` tag protects an unmapped private torrent after the next
qbit_manage run. Add a reviewed tracker mapping before relying on tracker-specific
policy:

```yaml
tracker:
  "tracker.example.org":
    tag:
      - tracker-private
      - tracker-example
  other:
    tag: tracker-public
```

A second dedicated private-tracker policy must receive its own tag and share-limit
group. Review that tracker's rules independently. Do not reuse CZTeam's values as a
generic private-tracker policy. Generalize the policy validator across all named
private groups when the second group is introduced.

## Operational interfaces

Use the read-only live verifier for workload, configuration, and policy state:

```bash
mise exec -- just kube qbit-manage-verify
```

Changing the qbit_manage Kustomization's `spec.suspend` through Git stops Flux
reconciliation. It does not stop the running Deployment or its 15-minute policy loop.
For an active policy incident, use the
[recovery runbook's workload-stop procedure](../runbooks/recovery.md#recover-a-qbit_manage-mistaken-clean).
That procedure leaves qBittorrent running so it can continue seeding. Disable cleanup by
changing both cleanup-enabled groups to `cleanup: false`; disable all share limits with
`commands.share_limits: false`. Make these changes through a reviewed pull request.

Do not publish qbit_manage logs. They can contain torrent names, tracker URLs, and
passkeys.
