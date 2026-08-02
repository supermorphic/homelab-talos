# Plex Relay and Sonos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Plex Relay permanently functional without an inbound WAN port, prove Plexamp and both Sonos integration directions, and contain a compromised Plex pod with an exact observed and source-declared Cilium allowlist.

**Architecture:** PR 1 adds an init-generated passwd identity for Plex's existing UID/GID `568`, pins the tested image digest, hardens the pod, and makes the media mount read-only. Retained diagnostics conditionally use the scoped diagnostic context while remaining operator-owned under canonical `AGENTS.md`; a guarded operator gate then proves Relay, native Sonos-library access, Plexamp-to-Sonos linking, and captures Plex flows. PR 2 adds the exact observed and source-declared Cilium policy—including Tautulli's accepted TCP `32400` dependency—and a guarded negative-path probe; it lands separately so policy regressions can be attributed and reverted independently.

**Tech Stack:** Flux GitOps, Kubernetes, bjw-s app-template `5.0.1`, Plex Media Server `1.43.3.10828`, Bash, Just, Helm, Kustomize, yq, Cilium `1.19.6`, Hubble CLI `1.19.3`, Conftest, and the repository test catalog.

## Global Constraints

- The approved decision is `docs/decisions/2026-08-02-plex-relay-sonos-design.md`.
- Do not add UniFi DNAT, a public Kubernetes Service, a public Gateway route, UPnP/NAT-PMP, Tailscale Funnel, Cloudflare Tunnel, a VPS tunnel, or an unauthenticated Plex CIDR.
- Keep the Plex Deployment single-replica with `Recreate` and the config PVC `ReadWriteOncePod`.
- Keep Plex at `runAsUser: 568`, `runAsGroup: 568`, and `fsGroup: 568`; do not migrate config, media, or GPU ownership.
- Use `ghcr.io/home-operations/plex:1.43.3.10828` at tested index digest `sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7` for both the app and identity init container.
- Never replace, seed, hash-compare, or mount Plex's `relayHostKey.txt`; Plex owns the native cache under `/config`.
- Preserve `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, non-root execution, and Intel GPU access; add RuntimeDefault seccomp and disable service-account token automount.
- Mount shared media read-only in Plex. `/config` remains the only persistent writable surface; `/transcode` and the generated passwd volume are ephemeral.
- All repository commands use `mise exec --`; all live-cluster commands are invoked only through guarded `just` recipes.
- No live or cluster-dependent check enters `just ci`.
- Canonical `AGENTS.md` continues to govern execution ownership: live verification,
  status, preflight, and diagnostic commands remain operator-only until that file is
  explicitly changed, even when a script can select a scoped diagnostic context.
- When `homelab-diagnostic` exists in the supplied kubeconfig, any retained Plex path
  using `pods/exec` or `pods/portforward` must select it conditionally; an operator
  kubeconfig without that named context continues using its current context.
- Do not commit the investigation-only live patch bypass (`scripts/experiment/plex-relay-live.sh` or its test). Replace the current worktree-only Just diff with the safe diagnostics defined below.
- Before each push, fetch `origin/main`; rebase only a clean branch when needed. Never merge or enable auto-merge without explicit authorization for that merge.

---

## PR 1 — Relay identity, deterministic hardening, and observability

### Task 1: Make the Plex validator express the permanent contract

**Files:**

- Modify: `scripts/validate/plex.sh`

**Interfaces:**

- Consumes: current Plex values and the pinned app-template Helm render.
- Produces: `mise exec -- just kube plex-validate` as the regression gate for every Relay identity and deterministic-hardening invariant used by later tasks.

- [ ] **Step 1: Add source assertions before changing the values**

Add these constants after the existing path variables:

```bash
image_repository='ghcr.io/home-operations/plex'
image_tag='1.43.3.10828'
image_digest='sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7'
controller='.controllers.plex'
```

Replace the loose image-tag checks with exact app/init assertions and add the pod, identity-volume, and media-mount assertions:

```bash
[[ "$(yq -r "$controller.pod.automountServiceAccountToken" "$values")" == 'false' ]]
[[ "$(yq -r "$controller.pod.securityContext.runAsNonRoot" "$values")" == 'true' ]]
[[ "$(yq -r "$controller.pod.securityContext.runAsUser" "$values")" == '568' ]]
[[ "$(yq -r "$controller.pod.securityContext.runAsGroup" "$values")" == '568' ]]
[[ "$(yq -r "$controller.pod.securityContext.fsGroup" "$values")" == '568' ]]
[[ "$(yq -r "$controller.pod.securityContext.seccompProfile.type" "$values")" == 'RuntimeDefault' ]]

for container in initContainers.runtime-identity containers.app; do
  [[ "$(yq -r "$controller.$container.image.repository" "$values")" == "$image_repository" ]]
  [[ "$(yq -r "$controller.$container.image.tag" "$values")" == "$image_tag" ]]
  [[ "$(yq -r "$controller.$container.image.digest" "$values")" == "$image_digest" ]]
  [[ "$(yq -r "$controller.$container.securityContext.allowPrivilegeEscalation" "$values")" == 'false' ]]
  [[ "$(yq -r "$controller.$container.securityContext.capabilities.drop | join(\",\")" "$values")" == 'ALL' ]]
done

identity_script="$(yq -r "$controller.initContainers.runtime-identity.args[0]" "$values")"
for required in \
  'cp /etc/passwd /runtime-identity/passwd' \
  'plex:x:568:568:Plex Media Server:/config:/usr/sbin/nologin' \
  'chmod 0644 /runtime-identity/passwd'; do
  rg -Fq -- "$required" <<<"$identity_script"
done
! rg -Fq 'relayHostKey' <<<"$identity_script"

[[ "$(yq -r '.persistence.runtime-identity.type' "$values")" == 'emptyDir' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.runtime-identity[0].path' "$values")" == '/runtime-identity' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.app[0].path' "$values")" == '/etc/passwd' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.app[0].subPath' "$values")" == 'passwd' ]]
[[ "$(yq -r '.persistence.runtime-identity.advancedMounts.plex.app[0].readOnly' "$values")" == 'true' ]]
[[ "$(yq -r '.persistence.media.advancedMounts.plex.app[0].path' "$values")" == '/Volumes/Prometheus' ]]
[[ "$(yq -r '.persistence.media.advancedMounts.plex.app[0].readOnly' "$values")" == 'true' ]]
[[ "$(yq -r '.persistence.media | has("globalMounts")' "$values")" == 'false' ]]
```

Also assert that both containers carry an explicit non-root identity; do not rely
only on pod inheritance for the security contract:

```bash
for container in initContainers.runtime-identity containers.app; do
  [[ "$(yq -r "$controller.$container.securityContext.runAsNonRoot" "$values")" == 'true' ]]
  [[ "$(yq -r "$controller.$container.securityContext.runAsUser" "$values")" == '568' ]]
  [[ "$(yq -r "$controller.$container.securityContext.runAsGroup" "$values")" == '568' ]]
done
```

- [ ] **Step 2: Add rendered Deployment assertions**

After `helm template`, select the Deployment once and assert its effective pod spec:

```bash
yq -o=yaml 'select(.kind == "Deployment" and .metadata.name == "plex")' \
  "$temp_dir/render.yaml" >"$temp_dir/deployment.yaml"
rendered="$temp_dir/deployment.yaml"

[[ "$(yq -r '.spec.template.spec.automountServiceAccountToken' "$rendered")" == 'false' ]]
[[ "$(yq -r '.spec.template.spec.securityContext.seccompProfile.type' "$rendered")" == 'RuntimeDefault' ]]
[[ "$(yq -r '.spec.template.spec.initContainers[] | select(.name == "runtime-identity") | .securityContext.runAsUser' "$rendered")" == '568' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.mountPath == "/etc/passwd") | .subPath' "$rendered")" == 'passwd' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.mountPath == "/etc/passwd") | .readOnly' "$rendered")" == 'true' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .volumeMounts[] | select(.mountPath == "/Volumes/Prometheus") | .readOnly' "$rendered")" == 'true' ]]
[[ "$(yq -r '.spec.template.spec.volumes[] | select(.name == "runtime-identity") | has("emptyDir")' "$rendered")" == 'true' ]]
```

Assert both rendered image strings equal:

```text
ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7
```

Assert the live-facing source remains private: Service type resolves to `ClusterIP`,
the only HTTPRoute parent is `internal`, and the route's ExternalDNS audience is
`internal`.

- [ ] **Step 3: Run the validator and verify the new contract fails**

Run:

```bash
mise exec -- just kube plex-validate
```

Expected: non-zero at the first missing hardening/identity assertion, because the
current values have no `runtime-identity` init container or digest.

- [ ] **Step 4: Commit the failing contract**

```bash
mise exec -- git add scripts/validate/plex.sh
mise exec -- git commit -m "test(plex): define relay identity contract"
```

---

### Task 2: Implement the init-generated identity and pod/filesystem hardening

**Files:**

- Modify: `kubernetes/apps/media/plex/app/values.yaml`

**Interfaces:**

- Consumes: the exact assertions from Task 1 and app-template `5.0.1` fields `pod.automountServiceAccountToken`, container `image.digest`, `initContainers`, and persistence `advancedMounts`.
- Produces: a rendered Deployment in which UID `568` resolves through `/etc/passwd`, Relay owns its native key cache, media is read-only, and the pod retains no Kubernetes API token.

- [ ] **Step 1: Add the pod-level security contract**

Under `controllers.plex.pod`, add:

```yaml
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 568
        runAsGroup: 568
        fsGroup: 568
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
```

Retain the current termination grace period.

- [ ] **Step 2: Add the non-root runtime-identity init container**

Add `controllers.plex.initContainers.runtime-identity` before `containers`:

```yaml
    initContainers:
      runtime-identity:
        image:
          repository: ghcr.io/home-operations/plex
          tag: 1.43.3.10828
          digest: sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7
        command: ["/bin/bash", "-ceu"]
        args:
          - |-
            cp /etc/passwd /runtime-identity/passwd
            if ! awk -F: '$3 == 568 { found=1 } END { exit !found }' /runtime-identity/passwd; then
              printf '%s\n' 'plex:x:568:568:Plex Media Server:/config:/usr/sbin/nologin' >>/runtime-identity/passwd
            fi
            awk -F: '$3 == 568 { found=1 } END { exit !found }' /runtime-identity/passwd
            chmod 0644 /runtime-identity/passwd
        securityContext:
          runAsNonRoot: true
          runAsUser: 568
          runAsGroup: 568
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
```

The script is idempotent if a future image supplies UID `568`. It validates the
generated file directly; `getent` is intentionally reserved for the started app
container, where `/etc/passwd` has been replaced by the read-only subPath mount.

- [ ] **Step 3: Pin and explicitly harden the app container**

Under `controllers.plex.containers.app.image`, retain the tag and add the same
`digest`. Under the app security context, explicitly add:

```yaml
          runAsNonRoot: true
          runAsUser: 568
          runAsGroup: 568
```

Keep `allowPrivilegeEscalation: false` and `capabilities.drop: ["ALL"]` unchanged.
Do not add `readOnlyRootFilesystem` in this implementation.

- [ ] **Step 4: Add the identity volume and convert media to an app-only read-only mount**

Add this persistence item:

```yaml
  runtime-identity:
    type: emptyDir
    advancedMounts:
      plex:
        runtime-identity:
          - path: /runtime-identity
        app:
          - path: /etc/passwd
            subPath: passwd
            readOnly: true
```

Replace `persistence.media.globalMounts` with:

```yaml
    advancedMounts:
      plex:
        app:
          - path: /Volumes/Prometheus
            readOnly: true
```

Keep the `media-data` claim, `/config`, `/transcode`, resource requests, probes, GPU
request/limit, Service, and internal HTTPRoute behavior unchanged.

- [ ] **Step 5: Run the focused source and render gates**

Run:

```bash
mise exec -- just kube plex-validate
mise exec -- just kube media-policy-validate
mise exec -- just kube kubeconform
```

Expected: all pass. Inspect the rendered Deployment if a field fails; do not weaken
Task 1 assertions to accommodate an unintended render.

- [ ] **Step 6: Commit the workload change**

```bash
mise exec -- git add kubernetes/apps/media/plex/app/values.yaml
mise exec -- git commit -m "fix(plex): provide relay runtime identity"
```

---

### Task 3: Add safe Relay status diagnostics and strengthen live verification

**Files:**

- Create: `scripts/diagnose/plex-relay-status.sh`
- Create: `scripts/test/plex-relay-status-test.sh`
- Modify: `scripts/verify/plex.sh`
- Modify: `kubernetes/mod.just`
- Modify: `tests/catalog.yaml`

**Interfaces:**

- Consumes: a running Plex pod selected by `app.kubernetes.io/name=plex` and the existing kubeconfig argument supplied by Just.
- Produces: `mise exec -- just kube plex-relay-status`, a read-only operator diagnostic that prints only boolean preflight facts and sanitized Relay lifecycle lines; enhanced `verification.plex` proves the permanent runtime identity and read-only mount.

- [ ] **Step 1: Write the failing diagnostic unit test**

Create a fake `kubectl` test following the repository's existing shell-test pattern.
The fake app-container response must include:

```text
relay_current_uid=568
relay_current_user=plex
relay_key_cache_readable=yes
relay_secure_connections_eligible=yes
Aug 02 DEBUG - Relay: starting relay PLEXTOKEN=secret-value
Aug 02 DEBUG - [PlexRelay] Authenticated to 203.0.113.10 user@example.com
Aug 02 INFO - [PlexRelay] Allocated port 31157 for remote forward to 127.0.0.1:32401
```

The test invokes `scripts/diagnose/plex-relay-status.sh <fake-kubeconfig>` and asserts:

```bash
rg -q '^relay_current_uid=568$' "$output"
rg -q '^relay_current_user=plex$' "$output"
rg -q '^relay_key_cache_readable=yes$' "$output"
rg -q '^relay_secure_connections_eligible=yes$' "$output"
rg -q 'Authenticated to 203\.0\.113\.10' "$output"
rg -q 'Allocated port 31157' "$output"
! rg -q 'secret-value|user@example\.com' "$output"
```

Also assert the fake command log contains only `get pods` and `exec`; no `patch`,
`apply`, `rollout`, `suspend`, `resume`, or Plex token appears in arguments.

- [ ] **Step 2: Run the diagnostic test and verify it fails**

Run:

```bash
mise exec -- bash scripts/test/plex-relay-status-test.sh
```

Expected: non-zero because `scripts/diagnose/plex-relay-status.sh` does not exist.

- [ ] **Step 3: Implement the read-only status script**

The script accepts exactly one kubeconfig argument, finds the running Plex pod, and
executes one non-interactive shell in the app container. Inside the pod it must:

```bash
uid="$(id -u)"
user="$(getent passwd "$uid" | cut -d: -f1)"
[[ "$uid" == '568' && "$user" == 'plex' ]]
printf 'relay_current_uid=%s\n' "$uid"
printf 'relay_current_user=%s\n' "$user"

key_file='/config/Library/Application Support/Plex Media Server/Cache/relayHostKey.txt'
[[ -r "$key_file" ]]
echo 'relay_key_cache_readable=yes'

prefs_file='/config/Library/Application Support/Plex Media Server/Preferences.xml'
secure_connections="$(xmlstarlet sel -T -t -v '/Preferences/@secureConnections' "$prefs_file")"
[[ "$secure_connections" == '1' || "$secure_connections" == '2' ]]
echo 'relay_secure_connections_eligible=yes'

tail -n 5000 '/config/Library/Application Support/Plex Media Server/Logs/Plex Media Server.log'
```

Capture the successful `kubectl exec` stdout in `raw_status`; this preserves a
non-zero remote preflight as a script failure. Then redact locally before selecting
the safe lines for stdout:

```bash
printf '%s\n' "$raw_status" | sed -E \
  -e 's/(PLEXTOKEN=)[^[:space:]]+/\1<redacted>/g' \
  -e 's/(X-Plex-Token=)[^&[:space:]]+/\1<redacted>/g' \
  -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<redacted-email>/g' |
  rg -i '^relay_|startRelay|Relay: starting relay|PlexRelay.*(Authenticated|Allocated port|exited)' || true
```

Do not read the Plex token or manually launch the Relay child.

- [ ] **Step 4: Add the guarded Just recipe**

Replace the worktree-only `plex-relay-experiment`, `plex-relay-live`, and inline
`plex-relay-live-logs` additions with one source-controlled recipe:

```just
# Print UID/key preflight facts and sanitized Plex Relay lifecycle lines without
# creating a session or mutating the cluster. Operator-only live diagnostic.
plex-relay-status: require-bash
    @scripts/diagnose/plex-relay-status.sh {{quote(kubeconfig)}}
```

The permanent branch must not contain a recipe that suspends Flux or patches the
live Deployment. After the safe replacement test passes, remove these exact
untracked investigation artifacts rather than staging them:

```bash
rm -- \
  scripts/diagnose/plex-relay-experiment.sh \
  scripts/experiment/plex-relay-live.sh \
  scripts/test/plex-relay-experiment-test.sh \
  scripts/test/plex-relay-live-experiment-test.sh
```

- [ ] **Step 5: Extend guarded live Plex verification**

After the current rollout check in `scripts/verify/plex.sh`, find the running Plex
pod and run one explicit app-container check:

```bash
pod="$(kubectl --kubeconfig "$kubeconfig" --namespace media get pods \
  --selector app.kubernetes.io/name=plex \
  --field-selector status.phase=Running \
  --output jsonpath='{.items[0].metadata.name}')"
kubectl --kubeconfig "$kubeconfig" --namespace media exec "$pod" -c app -- \
  /bin/bash -ceu '
    [[ "$(id -u)" == "568" ]]
    [[ "$(getent passwd 568 | cut -d: -f1)" == "plex" ]]
    [[ ! -e /var/run/secrets/kubernetes.io/serviceaccount/token ]]
    findmnt -n -o OPTIONS /Volumes/Prometheus | tr "," "\n" | rg -qx "ro"
    [[ -w /config ]]
  '
```

Keep this in `verification.plex`; it remains operator-owned and outside CI. Update
its catalog description to name runtime identity, API-token absence, and read-only
media as acceptance checks.

- [ ] **Step 6: Run focused tests**

Run:

```bash
mise exec -- bash scripts/test/plex-relay-status-test.sh
mise exec -- shellcheck scripts/diagnose/plex-relay-status.sh scripts/test/plex-relay-status-test.sh scripts/verify/plex.sh
mise exec -- just test validate
mise exec -- just kube plex-validate
```

Expected: all pass; no diagnostic output contains the fixture token or email.

- [ ] **Step 7: Commit diagnostics and verification**

```bash
mise exec -- git add scripts/diagnose/plex-relay-status.sh scripts/test/plex-relay-status-test.sh scripts/verify/plex.sh kubernetes/mod.just tests/catalog.yaml
mise exec -- git commit -m "test(plex): add relay acceptance diagnostics"
```

---

### Task 4: Add a bounded, read-only Hubble observer

**Files:**

- Modify: `.mise.toml`
- Modify: `mise.lock`
- Create: `scripts/diagnose/plex-network-observe.sh`
- Create: `scripts/test/plex-network-observe-test.sh`
- Modify: `kubernetes/mod.just`

**Interfaces:**

- Consumes: the repository kubeconfig and the Cilium Hubble Relay already deployed
  in `kube-system`.
- Produces: `mise exec -- just kube plex-network-observe 300`, a bounded,
  read-only L3/L4 observation of flows to and from the Plex endpoint. It creates
  only a local port-forward process, prints no packet payloads, and performs no
  Kubernetes mutation.

- [ ] **Step 1: Write the failing observer unit test**

Create fake `cilium`, `hubble`, and `sleep` executables. The fake `cilium` must
record and remain alive for `hubble port-forward`; fake `hubble status` must report
healthy; fake `hubble observe` must emit compact Plex flow fixtures. Assert the
script:

```text
requires exactly <kubeconfig> <duration-seconds>
rejects 0, 601, and non-numeric durations
invokes cilium hubble port-forward --kubeconfig <path>
waits on hubble status --server localhost:4245
invokes hubble observe --server localhost:4245 --namespace media --pod plex --follow --output compact
kills the exact observe PID after <duration> seconds
kills and waits for the exact background port-forward PID on success, timeout, and interrupt
```

Also reject `kubectl`, `create`, `apply`, `patch`, `delete`, `rollout`, `suspend`,
and `resume` anywhere in the fake command log.

- [ ] **Step 2: Run the observer test and verify it fails**

Run:

```bash
mise exec -- bash scripts/test/plex-network-observe-test.sh
```

Expected: non-zero because `scripts/diagnose/plex-network-observe.sh` does not
exist.

- [ ] **Step 3: Pin the compatible Hubble CLI**

Add this tool beside `cilium-cli` in `.mise.toml`:

```toml
"aqua:cilium/hubble" = "1.19.3"
```

Refresh and review the cross-platform lock using the repository's documented
tool-maintenance flow:

```bash
mise install
mise lock
mise exec -- hubble version
mise exec -- git diff -- .mise.toml mise.lock
```

Expected: Hubble CLI `v1.19.3`; only the Hubble package and platform artifacts are
added to `mise.lock`.

- [ ] **Step 4: Implement the bounded observer**

Use strict Bash mode. Validate that the kubeconfig is a file and that the duration
is an integer from `1` through `600`. Start the local Relay port-forward and capture
its PID:

```bash
temp_dir="$(mktemp -d)"
port_forward_pid=''
observe_pid=''
timer_pid=''
cleanup() {
  for pid in "$timer_pid" "$observe_pid" "$port_forward_pid"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf -- "$temp_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cilium hubble port-forward --kubeconfig "$kubeconfig" >/dev/null 2>&1 &
port_forward_pid=$!
```

Poll `hubble status --server localhost:4245` for at most 15 seconds:

```bash
hubble_ready='false'
for _ in {1..15}; do
  if hubble status --server localhost:4245 >/dev/null 2>&1; then
    hubble_ready='true'
    break
  fi
  sleep 1
done
[[ "$hubble_ready" == 'true' ]]
```

Then start the observer in the background, start a separate timer, and retain both
exact PIDs:

```bash
timeout_flag="$temp_dir/observe-timeout"
hubble observe \
  --server localhost:4245 \
  --namespace media \
  --pod plex \
  --follow \
  --output compact &
observe_pid=$!

(
  sleep "$duration"
  : >"$timeout_flag"
  kill -TERM "$observe_pid" 2>/dev/null || true
) &
timer_pid=$!

set +e
wait "$observe_pid"
observe_status=$?
set -e
kill "$timer_pid" 2>/dev/null || true
wait "$timer_pid" 2>/dev/null || true
[[ "$observe_status" == '0' || -f "$timeout_flag" ]]
```

Create `temp_dir` with `mktemp -d` and delete that exact directory in the cleanup
trap. A timer-triggered termination is the expected bounded completion; a Hubble
failure before the timer fires fails the recipe. Do not add `--print-raw-filters`,
debug logs, packet capture, or payload output.

- [ ] **Step 5: Add the read-only Just recipe**

Add beside the Relay status recipe:

```just
# Observe Plex L3/L4 Hubble flows for 1-600 seconds through a local port-forward.
# Operator-only and read-only; no packet payloads or cluster mutations.
plex-network-observe seconds='300': require-bash
    @scripts/diagnose/plex-network-observe.sh {{quote(kubeconfig)}} {{quote(seconds)}}
```

- [ ] **Step 6: Run focused tests and commit**

Run:

```bash
mise exec -- bash scripts/test/plex-network-observe-test.sh
mise exec -- shellcheck scripts/diagnose/plex-network-observe.sh scripts/test/plex-network-observe-test.sh
mise exec -- just test validate
```

Commit:

```bash
mise exec -- git add .mise.toml mise.lock scripts/diagnose/plex-network-observe.sh scripts/test/plex-network-observe-test.sh kubernetes/mod.just
mise exec -- git commit -m "feat(plex): add bounded flow observer"
```

---

### Task 5: Add the operator runbook and prepare PR 1

**Files:**

- Create: `docs/runbooks/plex-relay-sonos.md`

**Interfaces:**

- Consumes: the approved decision, `plex-verify`, `plex-relay-status`, and
  `plex-network-observe`.
- Produces: the exact operator-only configuration, functional acceptance, flow-capture checklist, failure interpretation, and rollback procedure used at the PR 1 gate.

- [ ] **Step 1: Write the runbook with exact Plex settings**

Document these values:

```text
Remote Access: enabled
Manually specify public port: disabled
Enable Relay: enabled
Secure connections: Required if the Sonos gate passes; otherwise Preferred
Strict TLS configuration: enable only after Plexamp and Sonos acceptance
Allowed without auth: empty
Remote streams allowed per user: 2
Custom server access URL: https://plex.lab.supermorphic.com
```

State explicitly that `LAN Networks` and **Treat WAN IP as LAN Bandwidth** are
bandwidth classification, not firewall or authentication controls.

- [ ] **Step 2: Document the three acceptance gates**

Include exact operator steps:

1. Run `mise exec -- just kube plex-verify`.
2. Run `mise exec -- just kube plex-relay-status` while initiating a remote client request.
3. Disable iPhone Wi-Fi and Tailscale, force-quit Plexamp, reopen it, browse Music, and play one track.
4. In the Sonos app, open Plex, select the Music library under **Other Libraries** if needed, browse, and play to a Sonos Port.
5. Connect the iPhone temporarily to an SSID mapped to VLAN 20; in the regular supported Plex iOS app open Players, select the Sonos link entry, and complete Sonos OAuth with the full Plex account.
6. Return the iPhone to Main Wi-Fi; in Plexamp verify the intended Sonos players appear and play one track without AirPlay.
7. Remove the temporary VLAN-20 SSID if one was created.

State that Gate 3 requires Plex Pass and that failure before the same-subnet OAuth
step is not evidence that Relay failed.

- [ ] **Step 3: Document safe failure interpretation and rollback**

Use this exact mapping:

| Evidence | Boundary |
|---|---|
| no `startRelay` event | Plex account/cloud/discovery |
| child exits before authentication | local identity/key/process |
| authenticated, no allocated port | Plex Relay service/path |
| allocated port, client cannot browse | client/account/library authorization |
| native Sonos can browse, Plexamp has no Sonos entry | Sonos account linking/local discovery |

Rollback is a Git revert of the Plex values commit through a reviewed PR. Do not
patch the Deployment, suspend Flux, mount a raw Relay key, enable an unauthenticated
CIDR, or open TCP `32400` as troubleshooting.

- [ ] **Step 4: Run the complete cluster-independent gate**

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

Expected: all pass with no live cluster command.

- [ ] **Step 5: Commit the runbook**

```bash
mise exec -- git add docs/runbooks/plex-relay-sonos.md
mise exec -- git commit -m "docs(plex): add relay and sonos runbook"
```

- [ ] **Step 6: Push and hand off PR 1**

On a clean branch:

```bash
mise exec -- git fetch origin main
mise exec -- git rebase origin/main
mise exec -- just ci
mise exec -- git push -u origin investigate-plex-remote-access
```

Open a PR titled `fix(plex): restore relay without public ingress`. Report the
tested digest, generated passwd mechanism, read-only media change, diagnostics,
validation actually run, and that no public ingress or live mutation was added.
Do not merge or enable auto-merge.

---

### Task 6: Align retained Plex diagnostics with scoped access

**Files:**

- Modify: `scripts/test/plex-relay-status-test.sh`
- Modify: `scripts/diagnose/plex-relay-status.sh`
- Modify: `scripts/test/plex-network-observe-test.sh`
- Modify: `scripts/diagnose/plex-network-observe.sh`

**Interfaces:**

- Consumes: a kubeconfig that may contain `homelab-diagnostic`, plus the existing
  operator-only guarded Just recipes.
- Produces: both retained diagnostics use the named diagnostic context when it exists
  and otherwise preserve the operator kubeconfig's current-context behavior.

- [ ] **Step 1: Add failing Relay-status context tests**

Extend the fake `kubectl` harness to expose two kubeconfig layouts. In the scoped case,
`kubectl config get-contexts homelab-diagnostic --no-headers` succeeds and every live
`get`/`exec` invocation must include `--context homelab-diagnostic`. In the operator
case, the context lookup fails and live invocations must not add a context flag.

- [ ] **Step 2: Run the Relay-status test and verify RED**

Run:

```bash
mise exec -- bash scripts/test/plex-relay-status-test.sh
```

Expected: non-zero because the status script does not yet select the diagnostic context.

- [ ] **Step 3: Implement minimal Relay-status context selection**

Use the same `kc=(kubectl --kubeconfig "$kubeconfig")` pattern as
`scripts/verify/plex.sh`. Append `--context homelab-diagnostic` only when the local
context lookup succeeds, then route both pod lookup and `exec` through `"${kc[@]}"`.

- [ ] **Step 4: Run the Relay-status test and verify GREEN**

Run the command from Step 2. Expected: all existing redaction and failure-preservation
cases plus both context-layout cases pass.

- [ ] **Step 5: Add failing network-observer context tests**

Extend the deterministic fake-client harness so the scoped case exposes
`homelab-diagnostic` and requires `cilium hubble port-forward` to receive
`--context homelab-diagnostic`. Add an operator-layout case proving no context flag is
forced when the named context is absent. Preserve all PID, signal, timeout, mutation-
client, and exact-status assertions.

- [ ] **Step 6: Run the observer test and verify RED**

Run:

```bash
mise exec -- bash scripts/test/plex-network-observe-test.sh
```

Expected: non-zero because the observer supplies only `--kubeconfig` today.

- [ ] **Step 7: Implement minimal observer context selection**

Inspect the local kubeconfig with pinned `kubectl config get-contexts`. Build Cilium
arguments with `--kubeconfig "$kubeconfig"` and append
`--context homelab-diagnostic` only when present. Do not change Hubble filters,
duration bounds, payload behavior, cleanup, or exit-status semantics.

- [ ] **Step 8: Run focused verification and commit**

Run:

```bash
mise exec -- bash scripts/test/plex-relay-status-test.sh
mise exec -- bash scripts/test/plex-network-observe-test.sh
mise exec -- shellcheck scripts/diagnose/plex-relay-status.sh scripts/diagnose/plex-network-observe.sh scripts/test/plex-relay-status-test.sh scripts/test/plex-network-observe-test.sh
mise exec -- just test validate
```

Expected: all pass. Commit only the four diagnostic/test files.

---

### Task 7: Run the PR 1 production acceptance and capture the Plex flow allowlist

**Files:**

- No source changes unless acceptance contradicts the approved decision.

**Interfaces:**

- Consumes: operator-authorized merge of PR 1, Flux reconciliation from current `origin/main`, and the Task 5 runbook.
- Produces: completed Relay/Sonos gates and a sanitized L3/L4 allowlist for PR 2.

- [ ] **Step 1: Wait for explicit merge authorization and verify deployed-source parity**

After the operator merges PR 1, fetch `origin/main`. Use only the existing guarded
verification/diagnostic recipes; if a recipe's deployed-source guard rejects the
revision, stop until Flux and `origin/main` agree.

- [ ] **Step 2: Run the permanent Relay and Plexamp gate**

Run:

```bash
mise exec -- just kube plex-verify
mise exec -- just kube plex-relay-status
```

Then perform Gate 1 from the runbook. Expected: Relay authenticates and allocates a
port, Plexamp browses, and one Music track plays over cellular with Wi-Fi and
Tailscale off.

- [ ] **Step 3: Run both Sonos gates**

Perform Gates 2 and 3 from the runbook. Expected: the native Sonos Plex service
browses/plays, then Sonos players appear in Plexamp on Main Wi-Fi and receive a
track without AirPlay after the one-time same-subnet account link.

If Gate 2 fails after Relay is allocated, reselect the Music library and reauthorize
the Plex music service before considering network changes. If Gate 3 fails on Main
but succeeds on VLAN 20, capture the blocked protocol before changing UniFi; do not
add broad multicast reflection.

- [ ] **Step 4: Record the required Plex flows before policy enforcement**

Start the bounded observer in a second terminal:

```bash
mise exec -- just kube plex-network-observe 300
```

While it runs, repeat:

- internal `https://plex.lab.supermorphic.com/identity`;
- Homepage Plex widget refresh;
- Seerr and each enabled `*arr` Plex connector test;
- Tautulli's direct Plex connection when Tautulli has been activated; when it remains
  suspended, retain its exact source-declared TCP `32400` contract and record that the
  selector has not yet been observed live;
- Plex library scan and metadata refresh;
- cellular Plexamp Relay browse/play; and
- native Sonos and Plexamp-to-Sonos playback.

The expected allowlist is:

```text
ingress TCP 32400: envoy-gateway-system, homepage, seerr, sonarr, radarr, lidarr, tautulli, host, remote-node
egress TCP/UDP 53: kube-dns
egress TCP 443: world
```

If a required successful action demonstrates an additional destination, protocol,
or port, stop before PR 2 and amend the approved decision and this plan with that
exact flow. Do not silently broaden `cluster`, Main-VLAN, IoT-VLAN, or `world`.

---

## PR 2 — Exact Cilium containment

### Task 8: Add the Plex Cilium policy contract before the policy

**Files:**

- Modify: `scripts/validate/plex.sh`
- Modify: `kubernetes/apps/media/plex/app/kustomization.yaml`

**Interfaces:**

- Consumes: the exact expected allowlist confirmed at Task 7.
- Produces: a failing source/render contract requiring one Plex-specific CiliumNetworkPolicy with no broader ingress or egress.

- [ ] **Step 1: Require the policy source and Kustomize wiring**

Add `kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml` to the validator's
required-file loop. Assert `kustomization.yaml` contains exactly one resource entry
for `./ciliumnetworkpolicy.yaml` in addition to the HelmRelease and HTTPRoute.

- [ ] **Step 2: Add exact policy assertions**

Parse the policy with yq and assert:

```text
kind = CiliumNetworkPolicy
metadata.name = plex
metadata.namespace = media
endpointSelector.matchLabels.app.kubernetes.io/name = plex
all ingress toPorts = TCP/32400
ingress sources = envoy-gateway-system, homepage, seerr, sonarr, radarr, lidarr, tautulli, host, remote-node
DNS egress = kube-dns TCP/53 and UDP/53
Internet egress = world TCP/443
```

Use structural yq assertions to reject all of these broad paths:

```text
ingress fromCIDR/fromCIDRSet containing 0.0.0.0/0
ingress fromCIDR/fromCIDRSet containing 192.168.10.0/24
ingress fromCIDR/fromCIDRSet containing 192.168.20.0/24
ingress fromCIDR/fromCIDRSet containing 192.168.90.0/24
ingress fromEntities containing world
egress toEntities containing cluster
egress toEntities containing host
egress toEntities containing remote-node
```

Require `toEntities: [world]` in exactly one egress rule and assert that rule has
only TCP `443`. Do not use whole-file string rejection for an entity that is valid
in another structural location.

- [ ] **Step 3: Add the policy resource entry without creating the file**

Add:

```yaml
  - ./ciliumnetworkpolicy.yaml
```

to the app Kustomization.

- [ ] **Step 4: Run the validator and verify it fails**

Run:

```bash
mise exec -- just kube plex-validate
```

Expected: non-zero because `ciliumnetworkpolicy.yaml` is required and absent.

- [ ] **Step 5: Commit the failing policy contract**

```bash
mise exec -- git add scripts/validate/plex.sh kubernetes/apps/media/plex/app/kustomization.yaml
mise exec -- git commit -m "test(plex): define network containment contract"
```

---

### Task 9: Implement the observed Plex CiliumNetworkPolicy

**Files:**

- Create: `kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml`

**Interfaces:**

- Consumes: the exact source contract from Task 8 and observed/source-declared allowlist from Task 7.
- Produces: default-deny behavior for the selected Plex endpoint with only required TCP `32400`, DNS, and world HTTPS paths.

- [ ] **Step 1: Create the policy**

Use this structure, keeping each named media app as a distinct endpoint selector:

```yaml
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: plex
  namespace: media
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: plex
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: envoy-gateway-system
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: homepage
            app.kubernetes.io/name: homepage
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: media
            app.kubernetes.io/name: seerr
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: media
            app.kubernetes.io/name: sonarr
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: media
            app.kubernetes.io/name: radarr
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: media
            app.kubernetes.io/name: lidarr
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: media
            app.kubernetes.io/name: tautulli
      toPorts:
        - ports:
            - port: "32400"
              protocol: TCP
    - fromEntities:
        - host
        - remote-node
      toPorts:
        - ports:
            - port: "32400"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    - toEntities:
        - world
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

If Task 7 approved an additional exact flow, add only that captured selector and
port to this source and to Task 8's structural assertions before proceeding.

- [ ] **Step 2: Run focused policy and render validation**

Run:

```bash
mise exec -- just kube plex-validate
mise exec -- just kube media-policy-validate
mise exec -- just kube cilium-validate
mise exec -- just kube kubeconform
```

Expected: all pass, with the Plex Kustomize build including one CNP and no public
Service/route.

- [ ] **Step 3: Commit the policy**

```bash
mise exec -- git add kubernetes/apps/media/plex/app/ciliumnetworkpolicy.yaml
mise exec -- git commit -m "feat(plex): contain pod network access"
```

---

### Task 10: Add a guarded positive/negative network-policy acceptance scenario

**Files:**

- Create: `scripts/test/scenarios/plex-network-policy.sh`
- Create: `scripts/test/plex-network-policy-guard-test.sh`
- Modify: `kubernetes/mod.just`
- Modify: `tests/catalog.yaml`

**Interfaces:**

- Consumes: a deployed Plex CNP, kubeconfig, and explicit confirmation `PLEX_NETWORK_POLICY_CONFIRM=test:plex-network-policy`.
- Produces: an operator-owned, mutating-but-self-cleaning scenario proving an unapproved pod cannot reach Plex while the approved gateway and Relay paths remain healthy.

- [ ] **Step 1: Write the guard/cleanup unit test**

Using fake `kubectl`, prove:

- no command runs without the exact confirmation;
- the target namespace is fixed to `testing` and probe name is prefixed
  `plex-policy-probe-`;
- the target IP comes only from a read-only lookup of Service `media/plex`, so DNS
  failure cannot create a false pass;
- the probe uses the already tested Plex image at
  `ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7`;
- a trap deletes only the run-scoped probe Pod;
- success requires the TCP/HTTP attempt from the unapproved probe to time out/fail;
  a successful connection fails the scenario; and
- cleanup runs on success, failed assertion, and interrupt.

Run:

```bash
mise exec -- bash scripts/test/plex-network-policy-guard-test.sh
```

Expected: non-zero before the scenario exists.

- [ ] **Step 2: Implement the guarded scenario**

The scenario must:

1. validate the exact confirmation and kubeconfig;
2. derive a DNS-safe run suffix without accepting a caller-supplied namespace/name;
3. read `media/plex` `.spec.clusterIP`, reject an empty value or `None`, and create
   one `restartPolicy: Never` probe Pod in `testing` using the exact tested
   Plex image and digest above, with
   `automountServiceAccountToken: false`, RuntimeDefault seccomp, non-root UID/GID,
   read-only root filesystem, dropped capabilities, and no privilege escalation;
4. run `timeout 10 /bin/bash -ceu` in that Pod and use Bash `/dev/tcp` to
   connect to the validated Plex Service IP on port `32400`, send
   `GET /identity HTTP/1.0\r\nHost: plex\r\n\r\n`, and treat any received HTTP
   status line as test failure; invert the connection command so the probe Pod
   exits `0` and prints `plex_policy_blocked=yes` only when the request fails;
5. delete only that exact Pod in a trap; and
6. after the negative assertion succeeds, call
   `scripts/verify/plex.sh "$kubeconfig"` and
   `scripts/diagnose/plex-relay-status.sh "$kubeconfig"` directly under the same
   top-level guarded Just invocation.

The script must never modify the CNP, Plex Deployment, Flux objects, namespaces,
Services, routes, or UniFi.

- [ ] **Step 3: Add the guarded recipe and catalog entry**

Add:

```just
# Prove an unapproved testing Pod cannot reach Plex while approved paths stay healthy.
# Operator-only and state-changing: creates and removes one run-scoped probe Pod.
plex-network-policy-test: require-bash
    @scripts/test/run-catalog-suite.sh test.plex-network-policy -- scripts/test/scenarios/plex-network-policy.sh {{quote(kubeconfig)}}
```

Add `test.plex-network-policy` to `tests/catalog.yaml` with:

```yaml
source: test
framework: bash
suite: media
tier: integration
target: plex
scenario: network-policy
scope: application
intent: acceptance
mutates_cluster: true
execution_owner: human
confirmation:
  type: exact
  variable: PLEX_NETWORK_POLICY_CONFIRM
  expected: test:plex-network-policy
```

Do not add it to any CI execution.

- [ ] **Step 4: Run offline tests and catalog validation**

Run:

```bash
mise exec -- bash scripts/test/plex-network-policy-guard-test.sh
mise exec -- shellcheck scripts/test/scenarios/plex-network-policy.sh scripts/test/plex-network-policy-guard-test.sh
mise exec -- just test validate
```

Expected: all pass.

- [ ] **Step 5: Commit the acceptance scenario**

```bash
mise exec -- git add scripts/test/scenarios/plex-network-policy.sh scripts/test/plex-network-policy-guard-test.sh kubernetes/mod.just tests/catalog.yaml
mise exec -- git commit -m "test(plex): prove network policy isolation"
```

---

### Task 11: Validate, hand off PR 2, and run final acceptance

**Files:**

- No additional source files.

**Interfaces:**

- Consumes: Tasks 7–9 and explicit operator authorization for PR 2 merge and the mutating policy scenario.
- Produces: the fully hardened accepted state and a bounded rollback path.

- [ ] **Step 1: Run the full cluster-independent gate**

Run:

```bash
mise exec -- just repo links-validate
mise exec -- just repo lint
mise exec -- just ci
```

Expected: all pass. Confirm `test.plex-network-policy` exists in the catalog but not
in `executions.ci`.

- [ ] **Step 2: Push and hand off PR 2**

On a clean branch based on the PR 1 merged `origin/main`:

```bash
mise exec -- git fetch origin main
mise exec -- git rebase origin/main
mise exec -- just ci
mise exec -- git push
```

Open a PR titled `feat(plex): enforce observed network containment`. Report the
captured allowlist, exact ingress/egress rules, offline validation, guarded test
design, and rollback. Do not merge or enable auto-merge.

- [ ] **Step 3: After explicit merge authorization, verify approved paths**

After Flux reconciles the merged `origin/main`, run:

```bash
mise exec -- just kube plex-verify
mise exec -- just kube plex-relay-status
```

Repeat all three functional gates from the runbook. Expected: local Plex, cellular
Plexamp Relay, native Sonos Plex playback, and Plexamp-to-Sonos playback all pass.

- [ ] **Step 4: Run the guarded negative-path scenario**

The operator sets the exact confirmation and runs:

```bash
PLEX_NETWORK_POLICY_CONFIRM='test:plex-network-policy' \
  mise exec -- just kube plex-network-policy-test
```

Expected: the unapproved testing Pod cannot reach Plex; it is removed; the approved
Plex verification and Relay status remain healthy.

- [ ] **Step 5: Roll back only if containment breaks a required path**

If any positive gate fails after the CNP lands, revert the PR 2 policy commit through
a reviewed PR, wait for Flux, and rerun `plex-verify` plus the three functional gates.
Do not widen the policy live. Preserve PR 1's runtime-identity and filesystem
hardening while the missing flow is investigated and documented.

---

## Completion criteria

- Plex Relay authenticates and allocates an ephemeral forward without a home inbound port.
- Plexamp browses and plays Music over cellular with Wi-Fi and Tailscale disabled.
- The native Sonos Plex service browses and plays the intended Music library.
- Sonos players appear in Plexamp on Main Wi-Fi and accept playback without AirPlay.
- Plex UID `568` resolves to `plex`; the native Relay key cache remains Plex-managed.
- Plex has no service-account token, uses RuntimeDefault seccomp, retains no added capability, and cannot write the shared media mount.
- Plex remains a `ClusterIP` behind only the internal Gateway; no UniFi DNAT exists.
- The Cilium policy allows only observed ingress, DNS, and world TCP `443` egress.
- A guarded negative probe from an unapproved namespace cannot reach Plex.
- `mise exec -- just ci` passes for both PRs, and live tests remain operator-owned outside CI.
