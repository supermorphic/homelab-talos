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

## Prepare the encrypted recovery unit

Do this in a clean feature branch based on `origin/main`. Retrieve the stable values from
the operator password manager. For a first installation only, create each value once with
a password generator and save it before continuing. For an existing or recovered
installation, use the saved values that match the database; do not create replacements.

Load the values without putting them in shell history:

```bash
IFS= read -r -s -p 'Stable N8N encryption key: ' N8N_ENCRYPTION_KEY; printf '\n'
IFS= read -r -s -p 'n8n database password: ' N8N_DB_PASSWORD; printf '\n'
IFS= read -r -s -p 'PostgreSQL superuser password: ' POSTGRES_SUPERUSER_PASSWORD; printf '\n'
IFS= read -r -s -p 'PostgreSQL backup-role password: ' POSTGRES_BACKUP_PASSWORD; printf '\n'
IFS= read -r -s -p 'PostgreSQL exporter password: ' POSTGRES_EXPORTER_PASSWORD; printf '\n'
IFS= read -r -s -p 'Platform Canary token: ' N8N_CANARY_TOKEN; printf '\n'
export N8N_ENCRYPTION_KEY N8N_DB_PASSWORD POSTGRES_SUPERUSER_PASSWORD
export POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD N8N_CANARY_TOKEN
N8N_SECRETS_CONFIRM='write:automation:n8n-platform:sops' \
  mise exec -- just repo n8n-secrets
unset N8N_ENCRYPTION_KEY N8N_DB_PASSWORD POSTGRES_SUPERUSER_PASSWORD
unset POSTGRES_BACKUP_PASSWORD POSTGRES_EXPORTER_PASSWORD N8N_CANARY_TOKEN
```

Select each generated ciphertext in its owning Kustomization:

- `./n8n-runtime.sops.yaml` in
  `kubernetes/apps/automation/n8n/app/kustomization.yaml`;
- `./postgresql-credentials.sops.yaml` in
  `kubernetes/apps/automation/n8n-postgresql/app/kustomization.yaml`; and
- `./n8n-canary.sops.yaml` in
  `kubernetes/apps/monitoring/gatus/app/kustomization.yaml`.

Keep `n8n-postgresql`, `n8n`, and `public-webhook-route` at `spec.suspend: true` in this
staging change. Validate and review only ciphertext and non-secret structure:

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

Wait for review, required checks, explicit merge authorization, the merge, and Flux source
revision parity with the merged `origin/main`. Do not bootstrap from an unmerged branch.

## Reconcile the private platform

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

## Create the owner and publish the canary privately

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

Create a second activation pull request that changes only `n8n-postgresql` and `n8n` to
`spec.suspend: false`. Validate, review, merge with explicit authorization, and wait for
Flux. Keep `public-webhook-route` suspended.

## Publish the exact public webhook

Complete these steps in order:

1. In internal Pi-hole DNS, add `hooks.lab.supermorphic.com` as an A record for the
   dedicated public-webhook VIP `192.168.90.39`. Confirm an internal client resolves that
   exact address.
2. In the authoritative public DNS provider, add `hooks.lab.supermorphic.com` for the
   router's current public address. Do not publish the editor hostname. Confirm an
   off-network client resolves the public record, not `192.168.90.39`.
3. Add one router port-forward rule: Internet TCP/443 to `192.168.90.39` TCP/443. Do not
   forward port 80, 5678, or 5432.
4. In a dedicated route-activation pull request, change only
   `public-webhook-route.spec.suspend` to `false`. Run
   `mise exec -- just kube n8n-validate`, obtain review and explicit merge authorization,
   merge, and wait for Flux readiness.
5. Confirm Gatus has loaded `Platform / n8n-platform-canary` and its five-minute probe is
   green. Run the full read-only verifier. It observes the Gatus series and does not send
   a webhook request or require the canary token:

```bash
mise exec -- just kube n8n-verify
```

## Focused n8n acceptance

Run this focused sequence for initial activation, an n8n upgrade, PostgreSQL changes, or
recovery changes:

```bash
mise exec -- just kube n8n-verify
mise exec -- just test smoke platform n8n
N8N_RESTORE_DRILL_CONFIRM='restore:n8n-postgresql:temporary' \
  mise exec -- just kube n8n-restore-drill
IFS= read -r -s -p 'Platform Canary token: ' N8N_CANARY_TOKEN; printf '\n'
export N8N_CANARY_TOKEN
CLUSTER_CHAOS_CONFIRM='chaos:n8n-persistence' \
  mise exec -- just test resilience n8n-persistence
unset N8N_CANARY_TOKEN
```

`n8n-verify` observes readiness, routes, monitoring, backup freshness, and the Gatus
canary series. The smoke suite checks the stable n8n resources without mutation. The
restore drill proves a temporary PostgreSQL restore can decrypt retained credentials. The
persistence test recreates the n8n and PostgreSQL pods and proves volume, canary, and
backup recovery. This is a focused acceptance sequence, not a new campaign.

The existing tier campaigns retain these entries: `verification.n8n` in `verification` and
`scoped-verification`; `chainsaw.smoke.platform.n8n` in smoke coverage; `test.n8n-restore-drill`
in `integration`; and `test.n8n-persistence` in `resilience`. Their aggregate placements
remain `standard`, `weekly`, and `full` as applicable. An operator running `weekly` or
`full` must export `N8N_CANARY_TOKEN` before the campaign starts and unset it afterward.
The catalog and campaign plan never contain its value.

## Off-network acceptance

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
  IFS= read -r -s -p 'Platform Canary token: ' canary_token; printf '\n'
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
case "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --connect-timeout 10 --max-time 30 \
  --request POST --header 'Content-Type: application/json' \
  --data '{"correlation":"negative-auth"}' \
  https://hooks.lab.supermorphic.com/webhook/platform-canary)" in
  400|401|403|404) ;;
  *) exit 1 ;;
esac
for path in / /rest/settings /metrics /webhook-test/platform-canary /webhook/unrelated; do
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    "https://hooks.lab.supermorphic.com${path}")" = 404
done
```

Open the returned positive execution ID immediately and require the matching successful
history record. Save no token or response payload in Git or test artifacts.

## Routine operation and controlled assurance

Use the read-only verifier for normal acceptance. The following mutating tests are
operator-run, use the shared cluster test Lease, and require their exact confirmations:

```bash
IFS= read -r -s -p 'Platform Canary token: ' N8N_CANARY_TOKEN; printf '\n'
export N8N_CANARY_TOKEN
CLUSTER_CHAOS_CONFIRM='chaos:n8n-persistence' \
  mise exec -- just test resilience n8n-persistence
unset N8N_CANARY_TOKEN
N8N_RESTORE_DRILL_CONFIRM='restore:n8n-postgresql:temporary' \
  mise exec -- just kube n8n-restore-drill
```

The persistence scenario recreates only the n8n and PostgreSQL pods and uses one exact
run-owned sentinel. The restore drill uses a temporary database and cluster-internal
resources. A cleanup or recovery failure makes either test fail.

Before an n8n upgrade, require a recent checksum-valid logical dump, review upstream
database migration notes, and complete the temporary restore drill. Do not assume that
reverting the container image can reverse a database migration.

## Public rollback

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
`public-webhook-route.spec.suspend: true`. Remove or disable the Gatus canary endpoint
only through a separate reviewed Git change if the public path will stay withdrawn. To
publish again, keep router forwarding disabled while a reviewed Git change re-adds
`./httproute.yaml` and sets the child Kustomization unsuspended. Wait for current Flux and
route acceptance, complete off-network tests, and restore forwarding last.

Do not delete the n8n, PostgreSQL, or backup claims during rollback. Keep the encrypted
recovery unit and logical dumps. Use the [n8n recovery runbook](../runbooks/n8n-recovery.md)
for data or database faults.
