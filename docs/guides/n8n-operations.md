# n8n operations

This guide activates and operates the n8n platform in its required dependency order. The
private editor is `https://n8n.lab.supermorphic.com`. The public interface at
`https://hooks.lab.supermorphic.com` permits only the exact paths declared in the
[public HTTPRoute](../../kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml),
after their activation checkpoints. That manifest is the source of truth for the
allowlist; `/webhook/platform-canary` is the initial example used throughout this guide.
PostgreSQL, the editor, the REST API, metrics, test webhooks, and all other webhook paths
stay private.

The logical PostgreSQL dumps and the SOPS-encrypted n8n runtime Secret are one recovery
unit. Keep the original `N8N_ENCRYPTION_KEY` in the operator password manager and in its
encrypted Git manifest for the life of the stored n8n data. A replacement key cannot
decrypt existing credential ciphertext.

## Choose the procedure

Use this guide according to the operation you need:

| Situation | Procedure |
| --- | --- |
| First installation or activation | Complete all three activation phases in order, then run activation acceptance and off-network acceptance. |
| Normal day-2 verification | Run the read-only `mise exec -- just kube n8n-verify` command. |
| n8n upgrade, PostgreSQL change, or recovery change | Run [activation, upgrade, and recovery-change acceptance](#activation-upgrade-and-recovery-change-acceptance). Before an n8n upgrade, also follow the backup and migration requirements in [day-2 operation and controlled assurance](#day-2-operation-and-controlled-assurance). |
| Withdraw public exposure | Follow [public exposure rollback](#public-exposure-rollback). Do not use workload suspension as a substitute for route pruning. |

The normal day-2 health check is read-only. Run it from a worktree with a current
`.kube/config`:

```bash
mise exec -- just kube n8n-verify
```

It observes readiness, routes, monitoring, backup freshness, and both Gatus n8n series.
It does not send a webhook request. The restore drill and persistence test are controlled,
mutating assurance tests. Do not use them as routine health checks.

The command blocks in the activation and rollback phases are attended operator
procedures. An explicit confirmation string is a safety guard; it does not make a
human-owned live mutation unattended or delegate its authority.
All operator shell blocks are compatible with interactive zsh and modern Bash. A block
that can terminate early runs in a subshell, so `exit` stops that block without closing
the operator's parent shell.

## Activation flow

Complete these Git transitions in order. Do not start the next transition until the
current phase has reached its completion checkpoint:

1. **Recovery material PR:** create and select the three encrypted Secrets while
   PostgreSQL, n8n, and the public route remain suspended.
2. **Private workload activation PR:** bootstrap PostgreSQL and n8n privately, complete
   the attended n8n UI setup and private canary checkpoint, then make the two private
   workloads active in Git. Keep the public route suspended.
3. **Public route + monitoring activation PR:** verify the Flux-managed internal DNS
   record, configure the one UniFi Cloudflare DDNS profile and router exposure, then
   activate the exact public route, Gatus webhook E2E check, and n8n alerts together
   through Git.

Every PR requires review, required checks, explicit merge authorization, merge, and Flux
source revision parity with the merged `origin/main` before the procedure advances.

## Phase 1 — Recovery material PR

**Start when:** The platform implementation is merged, this work starts in a clean feature
branch based on `origin/main`, and the operator has access to the password manager and the
operator-held age identity.

Do this in a clean feature branch based on `origin/main`. Retrieve the stable values from
the operator password manager. For a first installation only, create each value once with
a password generator and save it before continuing. For an existing or recovered
installation, use the saved values that match the database; do not create replacements.
The Platform Canary token has one contract everywhere it is used: at least 32 characters
from the base64url-safe alphabet `A-Z`, `a-z`, `0-9`, `_`, and `-`. Do not use padding,
spaces, quotes, backslashes, line breaks, or other punctuation. The Secret writer and the
persistence scenario reject values outside this contract before they write a manifest or
construct a curl configuration. The guarded writer checks every required value,
confirmation, minimum length, and token character before it creates a workspace, installs
a cleanup trap, or checks the age identity.

Load the values without putting them in shell history:

```bash
(
  printf '%s' 'Stable N8N encryption key: ' >&2
  IFS= read -r -s N8N_ENCRYPTION_KEY
  printf '\n' >&2
  printf '%s' 'n8n database password: ' >&2
  IFS= read -r -s N8N_DB_PASSWORD
  printf '\n' >&2
  printf '%s' 'PostgreSQL superuser password: ' >&2
  IFS= read -r -s POSTGRES_SUPERUSER_PASSWORD
  printf '\n' >&2
  printf '%s' 'PostgreSQL backup-role password: ' >&2
  IFS= read -r -s POSTGRES_BACKUP_PASSWORD
  printf '\n' >&2
  printf '%s' 'PostgreSQL exporter password: ' >&2
  IFS= read -r -s POSTGRES_EXPORTER_PASSWORD
  printf '\n' >&2
  printf '%s' 'Platform Canary token: ' >&2
  IFS= read -r -s N8N_CANARY_TOKEN
  printf '\n' >&2
  [[ "$N8N_CANARY_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
    unset N8N_CANARY_TOKEN
    echo 'The Platform Canary token does not satisfy the base64url contract.' >&2
    exit 1
  }
  export N8N_ENCRYPTION_KEY N8N_DB_PASSWORD POSTGRES_SUPERUSER_PASSWORD
  export POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD N8N_CANARY_TOKEN
  N8N_SECRETS_CONFIRM='write:automation:n8n-platform:sops' \
    mise exec -- just repo n8n-secrets
  unset N8N_ENCRYPTION_KEY N8N_DB_PASSWORD POSTGRES_SUPERUSER_PASSWORD
  unset POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD N8N_CANARY_TOKEN
)
```

Select each generated ciphertext in its owning Kustomization as part of the Recovery
material PR:

- `./n8n-runtime.sops.yaml` in
  `kubernetes/apps/automation/n8n/app/kustomization.yaml`;
- `./postgresql-credentials.sops.yaml` in
  `kubernetes/apps/automation/n8n-postgresql/app/kustomization.yaml`; and
- `./n8n-canary.sops.yaml` in
  `kubernetes/apps/monitoring/gatus/app/kustomization.yaml`.

The selected canary Secret does not yet affect the active Gatus Deployment. The required
environment reference and endpoint remain in
`kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml`, outside the
active `values.yaml`, until the public-route activation change.
The monitoring-owned `kubernetes/apps/monitoring/alerts/app/n8n.yaml` rule file also stays
unselected from `kubernetes/apps/monitoring/alerts/app/kustomization.yaml` until that same
activation change.

Keep `n8n-postgresql`, `n8n`, and `public-webhook-route` at `spec.suspend: true` in the
Recovery material PR. Validate and review only ciphertext and non-secret structure:

```bash
mise exec -- just kube n8n-validate
mise exec -- just repo validate
git diff --check
git status --short
git add kubernetes/apps/automation/n8n/app/n8n-runtime.sops.yaml \
  kubernetes/apps/automation/n8n/app/kustomization.yaml \
  kubernetes/apps/automation/n8n-postgresql/app/postgresql-credentials.sops.yaml \
  kubernetes/apps/automation/n8n-postgresql/app/kustomization.yaml \
  kubernetes/apps/monitoring/gatus/app/n8n-canary.sops.yaml \
  kubernetes/apps/monitoring/gatus/app/kustomization.yaml
git commit -m 'feat(automation): add encrypted n8n recovery unit'
git fetch origin
git rebase origin/main
mise exec -- just kube n8n-validate
mise exec -- just repo validate
git push -u origin HEAD
mise exec -- gh pr create
```

**Complete when:** The Recovery material PR has passed review and required checks, received
explicit merge authorization, merged, and reached Flux source revision parity with the
merged `origin/main`. `n8n-postgresql`, `n8n`, and `public-webhook-route` remain suspended.

**Stop if:** Secret generation, source validation, review, required checks, merge, or Flux
source parity fails. Preserve the stable values in the operator password manager, correct
the failed step, and do not bootstrap from an unmerged branch.

## Phase 2 — Private workload activation PR

**Start when:** The Recovery material PR is complete at Flux source revision parity, all
three ciphertext paths are selected, and `n8n-postgresql`, `n8n`, and
`public-webhook-route` remain suspended in Git.

### Reconcile the private platform

Refresh the task-owned kubeconfig, then run the guarded bootstrap. It checks deployed
source parity and all three ciphertext paths, reconciles the public Gateway foundation,
PostgreSQL, and n8n in order, creates the first validated logical backup from the
reconciled CronJob, and leaves the public route suspended. The bootstrap deletes only its
temporary backup Job after the validated artifact and freshness status exist.
This one-time Job is necessary because a new database has no backup status row before the
daily `01:00` UTC CronJob first succeeds. Its name and labels are unique to the bootstrap
invocation. If it fails or times out, the rollback trap prints only bounded Job status and
the last 80 backup-container log lines, removes and verifies absence of that exact Job,
then re-suspends the private workloads in reverse order.

```bash
mise exec -- just talos kubeconfig
N8N_BOOTSTRAP_CONFIRM='bootstrap:n8n' mise exec -- just bootstrap n8n
```

If private verification fails, the recipe re-suspends the PostgreSQL and n8n
Kustomizations that it resumed. It preserves the three claims and all diagnostic
resources. Fix the source or runtime fault before retrying.
Private verification also requires the staged `n8n-platform` Prometheus rule group to be
absent. A loaded group means alert activation happened early or stale alert state remains;
fix that state before retrying the private bootstrap.

### Create the owner and publish the canary privately

Open `https://n8n.lab.supermorphic.com` from the trusted private network and complete
these attended steps:

1. Create the one n8n owner account and store its password in the operator password
   manager.
2. Import
   `kubernetes/apps/automation/n8n/app/workflows/platform-canary.json`.
3. Create one Header Auth credential. n8n initially shows `Header Auth account` as the
   credential title at the top of its editor; rename that title exactly
   `Platform Canary Header`. In the **Connection** section, set **Name** to
   `X-Platform-Canary` and paste the saved Platform Canary token into **Value**. The
   credential title and the HTTP header name are different fields.
4. Bind `Platform Canary Header` to the imported workflow's `Webhook` node. Do not add
   the value to the workflow JSON.
5. Publish the `Platform Canary` workflow.
6. Send one authenticated request through the private path available to the operator.
   Require the JSON response to contain `status: ok`, the submitted correlation, and a
   non-empty execution ID.
7. Immediately open that execution ID in n8n execution history. Require `Succeeded` and
   the same correlation before continuing.

**Private canary checkpoint:** Do not create or merge the Private workload activation PR
until the authenticated private request has returned the expected response and the
matching execution is visibly `Succeeded` with the same correlation in n8n execution
history. If either check fails, stop with `public-webhook-route` suspended, correct the
private workflow or runtime fault, and repeat both checks.

The bootstrap logical backup predates this attended workflow and credential setup. Before
running the restore drill in activation acceptance, require a later successful scheduled
logical backup created after the credential was named, bound, and proven by the private
canary request. Do not use the bootstrap artifact to validate state created afterward.

### Make private workload activation permanent

Create the Private workload activation PR. It changes only `n8n-postgresql` and `n8n` to
`spec.suspend: false`. Validate it, obtain review and explicit merge authorization, merge
it, and wait for Flux source revision parity with the merged `origin/main`. Keep
`public-webhook-route` suspended.

**Complete when:** The private canary checkpoint passed, the Private workload activation
PR is merged at Flux source revision parity, PostgreSQL and n8n are ready, and
`public-webhook-route` remains suspended.

**Stop if:** Private bootstrap, private verification, the canary checkpoint, PR validation,
review, merge, Flux source parity, or workload readiness fails. Keep the public route
suspended. Use the bootstrap rollback behavior described above when it applies, and do not
prepare public exposure until the private phase completes.

## Phase 3 — Public route + monitoring activation PR

**Start when:** The Private workload activation PR is complete, PostgreSQL and n8n are
ready, the private canary checkpoint has passed, the split-DNS automation change is merged
at Flux source revision parity, and the public route remains suspended.

### Network and DNS exposure preparation

Complete these steps in order:

First, confirm the merged `public-webhook-gateway` package owns the only internally
published DNS endpoint and that ExternalDNS has observed its current generation and
reconciled it to Pi-hole. This read-only private verification also confirms the public
HTTPRoute remains absent:

```bash
N8N_VERIFY_MODE=private mise exec -- just kube n8n-verify
```

Stop if Pi-hole does not return exactly `192.168.90.39` for
`hooks.lab.supermorphic.com`. Do not add a manual Pi-hole record as a workaround.

1. In Cloudflare, [create a dedicated API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
   for UniFi DDNS. Grant only Zone Read and DNS Edit for the `supermorphic.com` zone. Save
   it in the operator password manager. Do not reuse the cert-manager token, commit this
   token, or place it in shell history or command output.
2. Follow the [UniFi Dynamic DNS procedure](https://help.ui.com/hc/en-us/articles/9203184738583-UniFi-Gateway-Dynamic-DNS)
   on the primary WAN Internet settings and create one entry with these values:

   - Service: `cloudflare`
   - Hostname: `hooks.lab.supermorphic.com`
   - Username: `supermorphic.com` (the Cloudflare zone name)
   - Password/API credential: the dedicated DDNS token
   - Server: leave unset unless the current UniFi Cloudflare form requires a value

   Cloudflare must be available as a native UniFi service. Stop if it is absent; do not
   substitute an unreviewed custom update server or hosted worker. After UniFi creates or
   updates the A record, confirm in Cloudflare that its proxy status is **DNS only** so
   public TLS terminates at Envoy. This is a one-time shared edge setting, not a step
   repeated for each webhook workflow.
3. From an off-network client, confirm `hooks.lab.supermorphic.com` resolves to the current
   WAN address shown by UniFi. It must not return `192.168.90.39` or another private
   address. A changing ISP address requires no operator edit; UniFi updates Cloudflare.
4. Add one router port-forward rule: Internet TCP/443 to `192.168.90.39` TCP/443. Do not
   forward port 80, 5678, or 5432.

**Complete when:** The private verifier confirms the Git-managed internal DNS endpoint and
Pi-hole answer, an off-network client resolves the UniFi-maintained Cloudflare record to
the current WAN address rather than the private VIP, and the router forwards only Internet
TCP/443 for this exposure to the dedicated VIP.

**Stop if:** The `DNSEndpoint` is absent, either DNS view is incorrect, UniFi DDNS is not
updating the current WAN address, or the forwarding rule is broader than the exact TCP/443
mapping. Keep `public-webhook-route` suspended and do not start the Git activation.

### Git-managed route and monitoring activation

In the dedicated Public route + monitoring activation PR, copy the staged Gatus webhook
E2E values into the active values, change `public-webhook-route.spec.suspend` to `false`,
and select the staged n8n rule:

```bash
mise exec -- yq -i '
  .env.GATUS_N8N_CANARY_TOKEN =
    load("kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml").env.GATUS_N8N_CANARY_TOKEN |
  del(.config.endpoints[] | select(.name == "n8n-webhook-e2e")) |
  .config.endpoints +=
    load("kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml").config.endpoints
' kubernetes/apps/monitoring/gatus/app/values.yaml
mise exec -- yq -i '
  (select(.metadata.name == "public-webhook-route") | .spec.suspend) = false
' kubernetes/apps/networking/public-webhook-gateway/ks.yaml
mise exec -- yq -i '
  .resources += ["./n8n.yaml"]
' kubernetes/apps/monitoring/alerts/app/kustomization.yaml
```

The Gatus validator rejects partial activation, duplicate webhook E2E entries, an
unselected canary Secret, or an active webhook E2E check while n8n, PostgreSQL, or the
public route is suspended. The alerts and n8n validators resolve every resource path from
the alerts Kustomization directory. They reject early or missing n8n rule selection,
aliases, and canonical or mixed duplicates; complete activation requires one literal
`./n8n.yaml`.
Run `mise exec -- just kube gatus-validate`,
`mise exec -- just kube n8n-validate`, and
`mise exec -- just kube alerts-validate monitoring`; obtain review and explicit merge
authorization, merge, and wait for Flux source revision parity with the merged
`origin/main` and Flux readiness. Once selected, the n8n Prometheus rule group stays
loaded and can alert during a Flux reconciliation failure or complete disappearance of
its source series.

**Complete when:** The Public route + monitoring activation PR passes all three validators,
review, and required checks; receives explicit merge authorization; merges; and reaches
Flux source revision parity with the merged `origin/main` and Flux readiness.

**Stop if:** Validation, review, required checks, merge, Flux source parity, or Flux
readiness fails. Do not treat the route as accepted and do not continue to public
verification.

### Monitoring and route verification

Confirm Gatus has loaded both `Automation / n8n-readiness` and
`Automation / n8n-webhook-e2e`. Require the one-minute readiness check and five-minute
webhook E2E check to be green. Run the full read-only verifier. It requires the exact
healthy 15-alert `n8n-platform` group, observes both Gatus series, and does not send a
webhook request or require the canary token:

```bash
mise exec -- just kube n8n-verify
```

**Complete when:** Both Gatus checks are green and `n8n-verify` confirms the exact healthy
15-alert group, expected route state, monitoring series, and backup freshness.

**Stop if:** Gatus or `n8n-verify` fails. Keep the failure evidence, correct the route,
monitoring, workload, or backup fault, and do not proceed to activation acceptance.

## Activation, upgrade, and recovery-change acceptance

Use this controlled assurance sequence for initial activation, an n8n upgrade, PostgreSQL
changes, or recovery changes. For initial activation, start only after Phase 3 monitoring
and route verification succeeds. For later changes, start after the intended Git revision
has reconciled and the affected workloads are ready.

The verifier and smoke suite are read-only. The restore drill and persistence test mutate
temporary or run-owned cluster state, use the shared test Lease, and require their exact
confirmations:

```bash
(
  set -euo pipefail
  mise exec -- just kube n8n-verify
  mise exec -- just test smoke platform n8n
  N8N_RESTORE_DRILL_CONFIRM='restore:n8n-postgresql:temporary' \
    mise exec -- just kube n8n-restore-drill
  printf '%s' 'Platform Canary token: ' >&2
  IFS= read -r -s N8N_CANARY_TOKEN
  printf '\n' >&2
  [[ "$N8N_CANARY_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
    unset N8N_CANARY_TOKEN
    echo 'The Platform Canary token does not satisfy the base64url contract.' >&2
    exit 1
  }
  export N8N_CANARY_TOKEN
  CLUSTER_CHAOS_CONFIRM='chaos:n8n-persistence' \
    mise exec -- just test resilience n8n-persistence
  unset N8N_CANARY_TOKEN
)
```

`n8n-verify` observes readiness, routes, monitoring, backup freshness, and both Gatus n8n
series. The smoke suite checks the stable n8n resources without mutation. The
restore drill proves a temporary PostgreSQL restore can decrypt retained credentials. The
persistence test recreates the n8n and PostgreSQL pods and proves volume, canary, and
backup recovery. This is a focused acceptance sequence, not a new campaign.

**Complete when:** All four commands succeed, including the temporary restore and
persistence recovery checks.

**Stop if:** Any command fails. Do not continue to off-network acceptance or declare the
change accepted. Preserve bounded failure output, correct the fault, and rerun the
controlled sequence.

The existing tier campaigns retain these entries: `verification.n8n` in `verification` and
`scoped-verification`; `chainsaw.smoke.platform.n8n` in smoke coverage; `test.n8n-restore-drill`
in `integration`; and `test.n8n-persistence` in `resilience`. Their aggregate placements
remain `standard`, `weekly`, and `full` as applicable. An operator running `weekly` or
`full` must export `N8N_CANARY_TOKEN` before the campaign starts and unset it afterward.
The catalog and campaign plan never contain its value.

## Off-network acceptance

**Start when:** Phase 3 and the activation acceptance sequence are complete, and the test
client can be disconnected from the LAN and private VPN.

Expected public behavior is narrow: an authenticated request to the exact production
canary succeeds and has a matching successful n8n execution. The same webhook without
authentication fails. The editor, REST API, metrics, test webhook, unrelated webhook, and
root paths remain unavailable. The positive and negative checks below prove both sides of
that boundary.

Disconnect the test client from the LAN and private VPN. Load the token with a silent
prompt and use a permission-restricted curl configuration so the header value does not
appear in process arguments:

```bash
(
  set -euo pipefail
  umask 077
  check_dir="$(mktemp -d "${TMPDIR:-/tmp}/n8n-off-network.XXXXXX")"
  cleanup_check_dir() {
    original_exit="$?"
    trap - EXIT INT TERM
    unset canary_token
    rm -rf -- "$check_dir" && test ! -e "$check_dir" || {
      echo 'Failed to remove the permission-restricted canary workspace.' >&2
      exit 1
    }
    exit "$original_exit"
  }
  trap cleanup_check_dir EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf '%s' 'Platform Canary token: ' >&2
  IFS= read -r -s canary_token
  printf '\n' >&2
  [[ "$canary_token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
    echo 'The Platform Canary token does not satisfy the base64url contract.' >&2
    exit 1
  }
  correlation="off-network-$(date -u +%Y%m%dT%H%M%SZ)"
  {
    printf '%s\n' 'silent' 'show-error' 'fail' 'connect-timeout = 10' \
      'max-time = 30' 'request = "POST"'
    printf '%s\n' 'header = "Content-Type: application/json"'
    printf 'header = "X-Platform-Canary: %s"\n' "$canary_token"
    printf 'data = "{\\"correlation\\":\\"%s\\"}"\n' "$correlation"
    printf '%s\n' 'url = "https://hooks.lab.supermorphic.com/webhook/platform-canary"'
    printf 'output = "%s/response.json"\n' "$check_dir"
  } >"$check_dir/request.curl"
  curl --config "$check_dir/request.curl"
  CORRELATION="$correlation" mise exec -- yq -e \
    '.status == "ok" and .correlation == strenv(CORRELATION) and
      (.executionId | type == "!!str" and length > 0)' \
    "$check_dir/response.json"
)
```

The exact webhook without authentication must fail. The editor, API, metrics, test
webhook, unrelated webhook, and root paths must also stay unavailable:

```bash
(
  case "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    --request POST --header 'Content-Type: application/json' \
    --data '{"correlation":"negative-auth"}' \
    https://hooks.lab.supermorphic.com/webhook/platform-canary)" in
    400|401|403|404) ;;
    *) exit 1 ;;
  esac
  for request_path in / /rest/settings /metrics /webhook-test/platform-canary /webhook/unrelated; do
    test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 30 \
      "https://hooks.lab.supermorphic.com${request_path}")" = 404
  done
)
```

Open the returned positive execution ID immediately and require the matching successful
history record. Save no token or response payload in Git or test artifacts.

**Complete when:** The authenticated response contains the expected status, correlation,
and execution ID; the matching history record is visibly successful; the unauthenticated
request fails with an allowed status; and every non-production path returns `404`.

**Stop if:** Any positive or negative assertion fails. Remove the router TCP/443 forwarding
rule first to contain public exposure, then investigate without weakening the exact route
or negative tests.

## Add a public webhook integration

Each integration receives one reviewed, non-overlapping `Exact` path on
`hooks.lab.supermorphic.com`. Reuse the existing Gateway, certificate, DNS records,
Service connectivity, and UniFi TCP/443 forward.

The integration's repository owns its workflow, authentication, credentials,
application data, provider lifecycle, monitoring, and acceptance procedures. Keep
those details there. This repository owns the public route and platform verification.

### Prepare the route change

1. Run `mise exec -- just kube n8n-verify` to confirm the existing edge is healthy.
2. Obtain the stable production path and confirmation from the integration owner that
   the receiver passed its private acceptance procedure and is ready for exposure.
   Keep the new path absent from the deployed route until that checkpoint passes.
3. Add one `Exact` match under `/webhook/` to the
   [public HTTPRoute](../../kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml).
   Update the source validator, live verifier, route-inventory tests, and smoke
   assertions in the same PR. Do not add a prefix, root, editor, API, metrics, or
   test-webhook route. No per-integration documentation inventory is required here.

The existing `ReferenceGrant` covers routes from `networking-public` to
`automation/n8n:5678`. A different backend requires separate review and a narrowly
scoped grant. Preserve the Platform Canary, its Gatus check, and negative-path tests.

Run the repository validation gate, which includes n8n, Gatus, and monitoring alerts:

```bash
mise exec -- just ci
git diff --check
```

Obtain review and operator merge authorization. Merge only after required checks and
private acceptance pass, then wait for Flux source revision parity and current Ready
conditions. Publishing a workflow alone does not add it to the public allowlist.

### Verify the public route

Run `mise exec -- just kube n8n-verify` after Flux reconciliation. From outside the LAN
and private VPN, confirm neighboring unlisted paths and the related test-webhook path
return `404`, and editor, API, metrics, and root paths remain unavailable. Confirm the
existing Platform Canary remains healthy.

The integration owner completes delivery and application acceptance using the owning
repository's procedure. Record repository validation, deployed route verification,
and integration acceptance separately; the platform verifier sends no webhook request
and cannot prove application behavior. Missing integration prerequisites leave that
acceptance pending.

If route or integration acceptance fails, remove only the new path through a reviewed
Git change and verify its removal after Flux reconciliation. Remove the shared UniFi
forward first only when broader containment is required.

### Remove one integration

Coordinate delivery shutdown with the integration owner using its repository's
procedure. Remove the exact path and update the route validation contracts in one
reviewed Git change. After Flux reconciliation, prove that path returns `404` while
the Platform Canary and remaining approved paths still work. Workflow, credential,
and application cleanup belong to the integration owner.

Keep the shared edge infrastructure while another approved path remains. If this is
the last public integration, use [public exposure rollback](#public-exposure-rollback),
including route pruning before suspension and router-forward removal ordering.

## Shared workflow failure notifications

Use `Platform Workflow Failure Handler` as the normal Error Workflow for automatic
production executions. Consumers choose it explicitly; a workflow may use another policy.
The handler sends one normal-priority notification to ntfy `homelab` per failed execution.
It does not retry the business workflow, recover missed schedules, or retain a delivery
queue. An ntfy outage can lose notifications. Keep existing platform monitoring enabled.

### One-time setup

1. Complete the [n8n ntfy publisher setup](ntfy-operations.md#n8n-workflow-failures),
   including the dedicated write-only identity and `Platform Failure ntfy` credential.
2. Import the secret-free
   [handler template](../../kubernetes/apps/automation/n8n/app/workflows/platform-workflow-failure.json)
   into the private n8n editor, or have the connected n8n MCP tools prepare it using
   [the handoff below](#mcp-preparation-and-credential-handoff).
   Check for an existing workflow with the exact name first;
   update that workflow in place on later changes so consumers retain its ID. Stop on
   duplicate names. Flux does not import or reconcile workflows.
3. Before binding a credential, require the HTTP Request node to use exactly **POST**
   to the fixed URL `http://ntfy.ntfy.svc.cluster.local` (root path), with no dynamic URL.
   Require JSON publish with fixed `topic: homelab` and `priority: 3`. Bind exactly the
   `Platform Failure ntfy` Header Auth credential. Leave the handler's own Error Workflow unset. Keep retries and redirects disabled and the request timeout
   at ten seconds. Keep saved successful, failed, manual, and intermediate execution data
   disabled: Error Trigger input can contain raw error context.
4. Check the handler's caller permissions allow the intended production workflows without
   maintaining a per-consumer allowlist. Use the existing trusted project/owner boundary.
5. Save and publish the handler, then perform synthetic acceptance below before adopting
   it in production.

For pinned n8n `2.36.7`, the
[error-workflow loader](https://github.com/n8n-io/n8n/blob/n8n%402.36.7/packages/cli/src/workflows/workflow-execution.service.ts)
loads the published workflow version and rejects a missing active version. General
[Error Trigger documentation](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.errortrigger/)
says publication is unnecessary. Follow the pinned implementation and prove it with an
automatic failure on this installation; recheck save/publish behavior after upgrades.
Manual editor executions do not prove Error Trigger delivery.

### MCP preparation and credential handoff

Use the connected n8n MCP tools for supported workflow creation, inspection, binding,
publication, and execution-history checks. The operator fills secret values in n8n's
credential editor from the password manager. Do not put tokens in chat, workflow
parameters, Git, or acceptance notes. The publisher credential still comes from
`ntfy-consumer-sync n8n`; do not manually replace its token as part of fixture setup.

Before asking the operator to enter values, prepare the workflows from the repository
templates in the same trusted project as the shared handler. Check for existing names
and record the exact IDs locally; stop on duplicates or uncertain ownership. Keep the
temporary workflows unpublished and disable their credential-dependent nodes until
their bindings are verified. Apply the template's workflow settings explicitly and
read them back; creating the graph alone does not prove retention or caller settings.

| Workflow | Node awaiting a credential | Required credential title |
| --- | --- | --- |
| `Platform Failure Fixture One` | `Synthetic Failure Webhook` | `Platform Failure Test Header` |
| `Platform Failure Fixture Two` | `Synthetic Failure Webhook` | The same `Platform Failure Test Header` credential |
| `Platform Failure Delivery Test Handler` (temporary copy of the shared handler) | `Publish Failure Notification` | `Platform Failure Invalid ntfy` |

Select the published shared handler as both fixtures' Error Workflow. Leave the test
handler's own Error Workflow unset. Unlike the shared handler, the temporary handler
copy saves failed execution data for the synthetic delivery-failure check.

Inspect the available MCP capabilities before handing off. A named SDK credential
placeholder is not proof that a stored credential was created. The current connection
can list and bind existing credentials, but has no credential-creation tool. Verify that
the prepared drafts have no unintended credential bindings before handoff. If a future
connection can create empty credentials, create those too and verify their metadata;
otherwise the operator creates them from the node's credential selector as follows:

1. Open `Platform Failure Fixture One`, then `Synthetic Failure Webhook`. Keep
   **Authentication** set to **Header Auth**. In its credential selector, create a new
   Header Auth credential, or open the prepared credential if one exists. The title at
   the top of the credential editor is separate from the header **Name** field.
2. Fill the fields below and save. Generate the test token once in the password manager:
   use at least 32 characters from `A-Z`, `a-z`, `0-9`, `_`, and `-`. This is a temporary
   webhook token, not the ntfy publisher token or an existing production secret.
3. Open `Platform Failure Delivery Test Handler`, then `Publish Failure Notification`.
   Keep **Authentication** set to **Generic Credential Type** and **Generic Auth Type**
   set to **Header Auth**. Create or open its separate credential and fill the second row.
   The invalid bearer value is deliberately synthetic; it needs no password-manager secret.

| Credential title | Connection → Name | Connection → Value |
| --- | --- | --- |
| `Platform Failure Test Header` | `X-Platform-Failure-Test` | Paste the temporary token from the password manager |
| `Platform Failure Invalid ntfy` | `Authorization` | Enter exactly `Bearer synthetic-invalid` |

Report only that the credentials are saved. The agent then resolves exactly one of each
title with type `httpHeaderAuth`, binds the same test credential to both fixture webhooks,
and binds only the invalid credential to the temporary handler copy. It reads back the
graph, settings, and credential IDs before enabling the prepared nodes. Publish each
workflow only when its step in synthetic acceptance requires it. Keep production
consumers unchanged until acceptance passes.

For the remaining handoffs, the operator sends the authenticated private requests below
when the agent has checked each phase's bindings, and inspects `homelab` using the
subscriber account. The agent checks matching execution metadata and the bounded fields
needed for acceptance; do not copy raw webhook headers into chat or artifacts. It
performs supported unpublication and cleanup operations. The current MCP connection
supports workflow archiving, but has no deletion tool for workflows, credentials, or
executions and no ntfy inbox reader. The operator completes those deletions in the UI
for the recorded test objects only. Archiving alone does not complete the cleanup step.
Report each remaining action with its workflow/node or credential title and the guide
step, so setup and acceptance do not depend on chat-only instructions.

### Consumer adoption and notification contract

In the consumer workflow's Settings, select `Platform Workflow Failure Handler` as its
**Error Workflow**, save, and publish the consumer as required by its trigger. For API-based
setup, resolve exactly one handler by its exact name, then use its instance ID as the
consumer's `settings.errorWorkflow`. Fail on zero or duplicate matches. Keep that ID in
the consumer's own deployment configuration, not a platform consumer inventory. Updating
an existing handler preserves bindings; deleting and reimporting it requires rebinding.
No `homelab-talos` change is required for a new consumer or automation-data domain.

Workflow and node names must be static, non-sensitive operational labels. The formatter
limits each name to 40 Unicode code points and normalizes control characters and
whitespace; it cannot infer whether a human
has put personal information into a name. The notification includes execution metadata
when available and constructs its link on the fixed private editor origin. Missing
execution details are explicitly labeled. A valid error timestamp is the failure time;
otherwise the notification labels the time as detection time.

The summary is fixed text. Raw error messages, stacks, provider responses, input/output
payloads, credentials, and domain data are excluded. Open the source execution in n8n for
details. Consumers that disable saved failed executions may have no retained execution to
open. Handled errors, continued failures, and failures before execution starts are subject
to n8n's native Error Trigger behavior; this is not a guarantee that every unsuccessful
business outcome generates a notification.

### Synthetic acceptance

This is an attended, controlled test: it publishes ntfy messages and creates temporary
workflow state. Use only the two repository fixtures and synthetic data. Do not bind
production credentials to them or invoke providers or domain databases. Run one acceptance
session at a time. Public artifacts contain only pass/fail results and fixture labels;
keep instance workflow and execution IDs in local acceptance notes for matching and
cleanup. Use the existing subscriber account to inspect `homelab`; the publisher token
cannot read messages.

1. Confirm the deployment runs the pinned version and `mise exec -- just kube n8n-verify`
   passes. Require the merged source revision to be reconciled, the dedicated identity
   synchronized, and no duplicate handler. Record the handler ID and its publication
   state. Immediately before use, check its three-node graph, exact POST to the fixed
   `http://ntfy.ntfy.svc.cluster.local` root URL, `Platform Failure ntfy` Header Auth
   binding, JSON `topic: homelab` and `priority: 3`, no downstream Error Workflow, disabled
   retries/redirects, ten-second HTTP timeout, and disabled execution-data retention.
2. Import the two inactive templates in
   [the fixture directory](../../tests/fixtures/n8n-failure-notifications/). Record their
   exact IDs. The templates are `Platform Failure Fixture One` and
   `Platform Failure Fixture Two`, with paths `platform-failure-fixture-one` and
   `platform-failure-fixture-two`. Bind both to the same handler ID and a temporary
   private Header Auth
   credential whose header **Name** is `X-Platform-Failure-Test` and whose **Value** is
   a fresh temporary token, using the
   [credential handoff](#mcp-preparation-and-credential-handoff). Reuse the prepared
   drafts when MCP has already created them. Use unique private webhook paths if a
   previous test occupies the fixture paths. Do not add public routes. After verifying
   both bindings, enable their webhook nodes if preparation disabled them, and publish
   both fixtures.
3. Send one authenticated POST to each fixture's **production webhook path through the
   private editor origin**, using [the request block below](#send-one-private-fixture-request)
   once for each fixture. The Stop And Error node must fail each automatic execution.
   Do not use the editor's Execute Workflow button or `/webhook-test/`. Record the two
   failed execution IDs and time of each request from n8n. These fixtures acknowledge
   receipt before failing, so an HTTP success response does not prove execution success.
4. Require exactly one `homelab` notification for each of those execution IDs. Verify
   distinct workflow names, the failing node, normal priority, time labels, fixed summary,
   and an execution link opening the corresponding failure in n8n. Inspect the actual
   stored ntfy messages: no synthetic sensitive marker from either fixture may appear.
   A formatter unit test or an HTTP response alone does not prove this delivery.
5. Prove a notification failure remains bounded using a **temporary copy** of the handler,
   with no Error Workflow and the same retry, redirect, and timeout settings. For this
   synthetic-only copy, temporarily save failed execution data to obtain test evidence;
   never make this retention change on the shared handler or bind a production workflow
   to the copy. Use the prepared `Platform Failure Delivery Test Handler` when present.
   Bind `Platform Failure Invalid ntfy`, verify the binding, and enable its HTTP node
   if preparation disabled it. Publish the copy, then bind Fixture One to that copy.
   Save/publish the changed fixture and send one automatic request with the same private
   request block. Require the delivery attempt to end with authentication
   failure, zero ntfy messages for that execution, and no recursive handler executions
   during a 60-second observation window. Inspect the copy's retained synthetic failure
   and execution list. The shared handler has no retained execution records by design.
   Restore and publish the fixture's binding to the shared handler and prove delivery
   again with one more private request. Record both additional fixture execution IDs
   and the temporary handler's failed execution ID, including any extra attempts needed
   to diagnose a failed check.
6. In a `finally`-style cleanup, unpublish the two recorded fixture IDs and the temporary
   handler copy. Delete all recorded fixture and temporary-handler executions, then
   remove those three test workflows and only their temporary credentials. The fixture
   records can include the temporary authentication header; include all four fixture
   requests from a successful acceptance session and any extra attempts. If deleting a
   workflow also removes its executions, verify their absence. Verify the temporary
   workflows are absent and their private production webhooks no
   longer execute. Keep the shared handler and its publisher credential. Cleanup failure
   means acceptance is incomplete even if notifications arrived.

After credential rotation, repeat positive delivery acceptance before finalizing the new
token. For upgrades, also confirm the handler executes the intended saved/published version
and caller permissions still permit both fixtures. Do not broaden permissions as a test
workaround.

### Send one private fixture request

Run this attended block only when the current acceptance step requires a request. For
positive acceptance, run it once with each fixture path. For the bounded-failure check
and the recovery check, run it once with Fixture One after its Error Workflow binding
has been checked and published for that phase. If setup required a different private
path, substitute that recorded path in the allowlist before running.

The block prompts without echo for the temporary token. It sends the token through
curl's standard input, does not follow redirects, and prints only the HTTP status. Use
the private editor origin even if n8n displays a production URL on the public hooks
origin; these fixture paths are intentionally absent from the public allowlist.

```bash
(
  printf '%s' 'Fixture path (platform-failure-fixture-one or platform-failure-fixture-two): ' >&2
  IFS= read -r fixture_path
  case "$fixture_path" in
    platform-failure-fixture-one|platform-failure-fixture-two) ;;
    *) echo 'Unrecognized fixture path.' >&2; exit 1 ;;
  esac
  printf '%s' 'Temporary failure-test token from password manager: ' >&2
  IFS= read -r -s failure_test_token
  printf '\n' >&2
  [[ "$failure_test_token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
    echo 'The test token must contain at least 32 base64url-safe characters.' >&2
    exit 1
  }
  {
    printf '%s\n' 'silent' 'show-error' 'fail' 'connect-timeout = 10' \
      'max-time = 30' 'request = "POST"' 'header = "Content-Type: application/json"'
    printf 'header = "X-Platform-Failure-Test: %s"\n' "$failure_test_token"
    printf '%s\n' 'data = "{}"'
    printf 'url = "https://n8n.lab.supermorphic.com/webhook/%s"\n' "$fixture_path"
  } | curl --disable --config - --output /dev/null --write-out 'HTTP %{http_code}\n'
)
```

An HTTP success is only an acknowledgement. Give the agent the fixture label, request
time, and HTTP status to match the failed automatic execution. Inspect the corresponding
ntfy message and report the content/link checks from acceptance step 4; keep tokens and
instance IDs out of public artifacts. After cleanup, repeat the request for each recorded
path and require `404` plus no new fixture execution. A response or execution indicating
that a fixture still runs means cleanup is incomplete. After these checks, remove the
temporary test token from the password manager.

**Activation status (2026-09-07):** the merged identity and workload changes are deployed;
live n8n, ntfy, and Alertmanager adapter verification passed. The operator reported
credential synchronization complete, and MCP confirmed the publisher credential and
published shared handler. The temporary test workflows are prepared but unpublished.
Automatic delivery, bounded-failure behavior, and test cleanup remain pending. Do not
treat handler publication or offline CI as proof of ntfy or phone delivery.

## Day-2 operation and controlled assurance

Use `mise exec -- just kube n8n-verify` for normal read-only day-2 verification. The
following mutating tests are operator-run, use the shared cluster test Lease, and require
their exact confirmations. Run them for the controlled assurance cases identified above,
not as routine health checks:

```bash
(
  printf '%s' 'Platform Canary token: ' >&2
  IFS= read -r -s N8N_CANARY_TOKEN
  printf '\n' >&2
  [[ "$N8N_CANARY_TOKEN" =~ ^[A-Za-z0-9_-]{32,}$ ]] || {
    unset N8N_CANARY_TOKEN
    echo 'The Platform Canary token does not satisfy the base64url contract.' >&2
    exit 1
  }
  export N8N_CANARY_TOKEN
  CLUSTER_CHAOS_CONFIRM='chaos:n8n-persistence' \
    mise exec -- just test resilience n8n-persistence
  unset N8N_CANARY_TOKEN
  N8N_RESTORE_DRILL_CONFIRM='restore:n8n-postgresql:temporary' \
    mise exec -- just kube n8n-restore-drill
)
```

The persistence scenario recreates only the n8n and PostgreSQL pods and uses one exact
run-owned sentinel. The restore drill uses a temporary database and cluster-internal
resources. A cleanup or recovery failure makes either test fail.

Before an n8n upgrade, require a recent checksum-valid logical dump, review upstream
database migration notes, and complete the temporary restore drill. Do not assume that
reverting the container image can reverse a database migration.

## Public exposure rollback

**Start when:** The operator has decided to withdraw the public webhook because of an
incident, failed public acceptance, maintenance boundary, or deliberate removal.

Remove the router TCP/443 forwarding rule first. Confirm an off-network connection can no
longer reach the host, then disable the UniFi DDNS profile and remove the public Cloudflare
record. Keep the Git-managed internal `DNSEndpoint`; do not replace it with a manual
Pi-hole record. Suspension alone does not prune
an already applied route. In the first reviewed containment change, keep
`public-webhook-route.spec.suspend: false` and change
`kubernetes/apps/networking/public-webhook-gateway/route/kustomization.yaml` to
`resources: []`. This is a valid empty Kustomization; validate it with
`mise exec -- kustomize build kubernetes/apps/networking/public-webhook-gateway/route`
and `mise exec -- just kube n8n-validate`. Merge with explicit authorization and let the
unsuspended child reconcile with `prune: true`.

After Flux observes the merged generation, prove the route is absent:

```bash
route_state="$(mise exec -- kubectl --kubeconfig .kube/config --namespace flux-system \
  get kustomization public-webhook-route --output json)"
mise exec -- yq -e '
  .spec.suspend == false and
  .metadata.generation == .status.observedGeneration and
  (.metadata.generation as $generation |
    [.status.conditions[]? | select(.type == "Ready" and .status == "True" and
      .observedGeneration == $generation)] | length == 1)
' <<<"$route_state"
test -z "$(mise exec -- kubectl --kubeconfig .kube/config \
  --namespace networking-public get httproute n8n-platform-canary \
  --ignore-not-found --output name)"
```

Only after that proof may a second reviewed Git change set
`public-webhook-route.spec.suspend: true`. If the public path will stay withdrawn, remove
both `GATUS_N8N_CANARY_TOKEN` and the `n8n-webhook-e2e` endpoint from active
`values.yaml`; keep the exact reactivation source in
`n8n-canary-activation.values.yaml`, and remove `./n8n.yaml` from the monitoring alerts
Kustomization in the same reviewed change. To publish again, keep router forwarding
disabled while one reviewed Git change re-adds `./httproute.yaml`, sets the child
Kustomization unsuspended, copies the staged Gatus fragment into active values, and
selects `./n8n.yaml` exactly once. Wait for current Flux and route acceptance, complete
off-network tests, re-enable and verify the one UniFi DDNS profile, and restore forwarding
last.

**Complete when:** External forwarding and the UniFi-maintained public DNS record are
removed, the unsuspended child
Kustomization has reconciled the empty route source with pruning, the exact HTTPRoute is
proved absent, and only then the follow-up Git change suspends the child. If exposure will
stay withdrawn, the Gatus webhook E2E check and n8n alert selection are removed in that
same reviewed change as described above. Keep the private `n8n-readiness` check active.

**Stop if:** The off-network containment check or route-absence proof fails. Do not suspend
the child Kustomization before pruning is observed, and do not delete the retained claims
or recovery material.

Do not delete the n8n, PostgreSQL, or backup claims during rollback. Keep the encrypted
recovery unit and logical dumps. Use the [n8n recovery runbook](../runbooks/n8n-recovery.md)
for data or database faults.
