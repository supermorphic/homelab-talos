# n8n operations

This guide activates and operates the n8n platform in its required dependency order. The
private editor is `https://n8n.lab.supermorphic.com`. The only public interface is the
exact production webhook `https://hooks.lab.supermorphic.com/webhook/platform-canary`.
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

It observes readiness, routes, monitoring, backup freshness, and the Gatus canary series.
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
3. **Public route + monitoring activation PR:** prepare DNS and router exposure, then
   activate the exact public route, Gatus canary, and n8n alerts together through Git.

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
3. Create one Header Auth credential named `Platform Canary Header`. Set the header name
   to `X-Platform-Canary` and paste the saved Platform Canary token as its value.
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
ready, the private canary checkpoint has passed, and the public route remains suspended.

### Network and DNS exposure preparation

Complete these steps in order:

1. In internal Pi-hole DNS, add `hooks.lab.supermorphic.com` as an A record for the
   dedicated public-webhook VIP `192.168.90.39`. Confirm an internal client resolves that
   exact address.
2. In the authoritative public DNS provider, add `hooks.lab.supermorphic.com` for the
   router's current public address. Do not publish the editor hostname. Confirm an
   off-network client resolves the public record, not `192.168.90.39`.
3. Add one router port-forward rule: Internet TCP/443 to `192.168.90.39` TCP/443. Do not
   forward port 80, 5678, or 5432.

**Complete when:** Internal DNS resolves the dedicated public-webhook VIP, an off-network
client resolves the public record rather than the private VIP, and the router forwards
only Internet TCP/443 for this exposure to the dedicated VIP.

**Stop if:** Either DNS view is incorrect or the forwarding rule is broader than the exact
TCP/443 mapping. Keep `public-webhook-route` suspended and do not start the Git activation.

### Git-managed route and monitoring activation

In the dedicated Public route + monitoring activation PR, copy the staged Gatus canary
values into the active values, change `public-webhook-route.spec.suspend` to `false`, and
select the staged n8n rule:

```bash
mise exec -- yq -i '
  .env.GATUS_N8N_CANARY_TOKEN =
    load("kubernetes/apps/monitoring/gatus/app/n8n-canary-activation.values.yaml").env.GATUS_N8N_CANARY_TOKEN |
  del(.config.endpoints[] | select(.name == "n8n-platform-canary")) |
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

The Gatus validator rejects partial activation, duplicate canary entries, an unselected
canary Secret, or active canary values while n8n, PostgreSQL, or the public route is
suspended. The alerts and n8n validators resolve every resource path from the alerts
Kustomization directory. They reject early or missing n8n rule selection, aliases, and
canonical or mixed duplicates; complete activation requires one literal `./n8n.yaml`.
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

Confirm Gatus has loaded `Platform / n8n-platform-canary` and its five-minute probe is
green. Run the full read-only verifier. It requires the exact healthy 15-alert
`n8n-platform` group, observes the Gatus series, and does not send a webhook request or
require the canary token:

```bash
mise exec -- just kube n8n-verify
```

**Complete when:** The five-minute Gatus probe is green and `n8n-verify` confirms the exact
healthy 15-alert group, expected route state, monitoring series, and backup freshness.

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

`n8n-verify` observes readiness, routes, monitoring, backup freshness, and the Gatus
canary series. The smoke suite checks the stable n8n resources without mutation. The
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
longer reach the host, then remove the public DNS record. Suspension alone does not prune
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
both `GATUS_N8N_CANARY_TOKEN` and the `n8n-platform-canary` endpoint from active
`values.yaml`; keep the exact reactivation source in
`n8n-canary-activation.values.yaml`, and remove `./n8n.yaml` from the monitoring alerts
Kustomization in the same reviewed change. To publish again, keep router forwarding
disabled while one reviewed Git change re-adds `./httproute.yaml`, sets the child
Kustomization unsuspended, copies the staged Gatus fragment into active values, and
selects `./n8n.yaml` exactly once. Wait for current Flux and route acceptance, complete
off-network tests, and restore forwarding last.

**Complete when:** External forwarding and public DNS are removed, the unsuspended child
Kustomization has reconciled the empty route source with pruning, the exact HTTPRoute is
proved absent, and only then the follow-up Git change suspends the child. If exposure will
stay withdrawn, the Gatus canary and n8n alert selection are removed in that same reviewed
change as described above.

**Stop if:** The off-network containment check or route-absence proof fails. Do not suspend
the child Kustomization before pruning is observed, and do not delete the retained claims
or recovery material.

Do not delete the n8n, PostgreSQL, or backup claims during rollback. Keep the encrypted
recovery unit and logical dumps. Use the [n8n recovery runbook](../runbooks/n8n-recovery.md)
for data or database faults.
