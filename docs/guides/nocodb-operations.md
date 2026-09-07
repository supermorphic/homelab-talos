# NocoDB operations

This guide stages and operates the private NocoDB interface for selected
automation-data PostgreSQL domains. NocoDB is an optional operator interface. PostgreSQL
remains the authority boundary, and n8n remains the workflow and bulk-change boundary.

The NocoDB package is present in Git with its Flux Kustomization suspended. The live
bootstrap, source acceptance, logical backup, and restore drill have not run. Do not
claim that NocoDB is active or recoverable until the attended rollout in this guide has
completed and its evidence has been reviewed.

The repository procedures are reconciled with the tested offline and disposable local
implementation described in [specification 028](../specs/028-nocodb-operator-ui.md).
Before activation, complete the operator-run existing-platform upgrade and attended
cluster acceptance for the deployed revision. This local evidence does not prove live
access, browser behavior, backup publication, restore behavior, or activation.

Use [Staged activation](#staged-activation) for the first deployment and
[Routine operation](#routine-operation) afterward. For failure classification and
recovery, use [Recover NocoDB](../runbooks/nocodb-recovery.md).

## Before you start

Start activation only when all of these conditions are true:

- the automation-data platform bootstrap, provisioning acceptance, current complete
  backup, and full-chain restore drill have passed for the deployed revision;
- the checkout is clean and exactly matches deployed `origin/main`;
- the operator has the SOPS age private key, task-scoped cluster credentials, private
  access to NocoDB and n8n, and access to the test report catalog;
- the operator has the full-access Community-edition n8n API key needed by bootstrap;
- the operator can retain the NocoDB connection encryption key and can access complete
  automation-data logical bundles; and
- all secret values can stay in the operator environment, standard input, password
  manager, or encrypted Secret. Do not send them to an agent or place them in Git,
  command arguments, logs, or saved workflow executions.

Obtain task-scoped credentials before an attended live command:

```bash
mise exec -- just talos kubeconfig
```

Stop if a guarded command fails, source revision parity is absent, an expected object is
duplicated, or a required read-back does not match. Do not bypass a guard or continue to
the next lifecycle phase after a failure.

## Authority and data surfaces

Each Noco-enabled domain has two separate PostgreSQL surfaces:

- `read_model` contains workflow-produced facts and reviewed read-only projections. The
  `<domain>_reader` login receives only `CONNECT`, schema `USAGE`, and `SELECT` on this
  schema. Its NocoDB source disables data and schema editing.
- `operator` contains human decisions, notes, priorities, follow-up state, and explicit
  correction or override records. The `<domain>_operator` login receives only the exact
  reviewed DML grants in this schema. Its NocoDB source permits data editing but disables
  schema editing.

The operator login does not inherit the reader surface. It is not a general update path
to source facts. Preserve source facts and record corrections in `operator`. Use n8n or
the domain migrator for schema changes, backfills, bulk changes, and changes across many
records. PostgreSQL grants remain authoritative even if a NocoDB UI flag is wrong.

The reviewed revision also revokes inherited `PUBLIC CONNECT` on the `postgres` and
`template1` maintenance databases. Reader and operator validation covers all connectable
databases, including connectable templates, and accepts `CONNECT` only to the selected
domain database. Do not restore either public grant as a source-connectivity workaround.

NocoDB uses one application pod, no worker, and no Redis. Application-local storage is
ephemeral, and the Deployment uses `Recreate`. PostgreSQL stores supported durable
metadata, encrypted source credentials, bases, views, and application configuration.
Do not use local NocoDB uploads for durable files. This deployment does not configure a
native-attachment override, but it does not claim to disable every upload API.

## Recovery roots

Retain these materials outside the cluster:

- the SOPS age private key;
- the exact `NC_CONNECTION_ENCRYPT_KEY` stored in the encrypted NocoDB Secret;
- access to complete automation-data logical bundles; and
- the operator account and private n8n access needed for attended administration.

The automation-data logical bundle preserves the `nocodb` metadata database, the source
registry, optional role definitions, role password verifiers, operator decisions, and
durable artifact metadata and references. Workflow or storage owners retain and recover
the referenced external file bytes separately. NocoDB recovery does not fetch or validate
those bytes and does not define a general artifact service or schema.

## Staged activation

### 1. Create the encrypted NocoDB Secret

From a clean feature branch, set the six initial-creation values without putting them in
shell history, then run:

```bash
mise exec -- just repo nocodb-secrets
```

The guarded writer requires:

| Variable | Purpose |
| --- | --- |
| `NOCODB_METADATA_PASSWORD` | Password for the dedicated `nocodb_metadata` login |
| `NOCODB_AUTH_JWT_SECRET` | NocoDB JWT signing secret |
| `NOCODB_CONNECTION_ENCRYPT_KEY` | Stable key that encrypts stored source credentials |
| `NOCODB_ADMIN_EMAIL` | Initial local administrator email |
| `NOCODB_ADMIN_PASSWORD` | Initial local administrator password |
| `NOCODB_SOURCE_PROVISIONING_HEADER` | Bare private source-webhook authentication token |
| `NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY` | Update-only proof that must exactly equal the decrypted retained connection encryption key |

Set `NOCODB_SECRETS_CONFIRM='write:automation-data:nocodb:sops'` only after reviewing the
target. A safe invocation can read values silently inside a subshell:

```bash
(
  printf '%s' 'NocoDB metadata password: ' >&2
  IFS= read -r -s NOCODB_METADATA_PASSWORD
  printf '\n%s' 'NocoDB JWT secret: ' >&2
  IFS= read -r -s NOCODB_AUTH_JWT_SECRET
  printf '\n%s' 'NocoDB connection encryption key: ' >&2
  IFS= read -r -s NOCODB_CONNECTION_ENCRYPT_KEY
  printf '\n%s' 'NocoDB administrator email: ' >&2
  IFS= read -r NOCODB_ADMIN_EMAIL
  printf '%s' 'NocoDB administrator password: ' >&2
  IFS= read -r -s NOCODB_ADMIN_PASSWORD
  printf '\n%s' 'NocoDB source provisioning header: ' >&2
  IFS= read -r -s NOCODB_SOURCE_PROVISIONING_HEADER
  if [[ -f kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml ]]; then
    printf '\n%s' 'Existing decrypted NocoDB connection encryption key: ' >&2
    IFS= read -r -s NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY
    export NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY
  fi
  printf '\n' >&2
  export NOCODB_METADATA_PASSWORD NOCODB_AUTH_JWT_SECRET
  export NOCODB_CONNECTION_ENCRYPT_KEY NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD
  export NOCODB_SOURCE_PROVISIONING_HEADER
  NOCODB_SECRETS_CONFIRM='write:automation-data:nocodb:sops' \
    mise exec -- just repo nocodb-secrets
  unset NOCODB_METADATA_PASSWORD NOCODB_AUTH_JWT_SECRET
  unset NOCODB_CONNECTION_ENCRYPT_KEY NOCODB_ADMIN_EMAIL NOCODB_ADMIN_PASSWORD
  unset NOCODB_SOURCE_PROVISIONING_HEADER NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY
)
```

The writer creates or updates
`kubernetes/apps/automation-data/nocodb/app/nocodb-credentials.sops.yaml`. On first
creation, `NOCODB_CONNECTION_ENCRYPT_KEY` becomes the retained key. On every update,
retrieve that key through the approved SOPS workflow and enter the same retained value
for both `NOCODB_CONNECTION_ENCRYPT_KEY` and
`NOCODB_CONNECTION_ENCRYPT_KEY_RECOVERY`. The recovery variable is proof, not a
replacement input: the writer decrypts the existing Secret, verifies the proof, and
writes the existing key back. It never replaces the retained key. Review only ciphertext
and non-secret structure. Merge the Secret while `nocodb.spec.suspend` remains `true`,
then wait for Flux source parity.

**Expected result:** The encrypted Secret is selected by the application Kustomization,
contains only SOPS ciphertext, and the Git-managed NocoDB Kustomization remains
suspended.

### 2. Bootstrap NocoDB and its n8n API credential

From a clean checkout that equals deployed `origin/main`, export the existing full-access
n8n API key as `N8N_API_KEY`, then run:

```bash
NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb' mise exec -- just bootstrap nocodb
```

Bootstrap verifies the issue-317 prerequisite evidence, encrypted Secret, deployed
revision, and live suspension twice before mutation. Provisioning and restore reports
retain the Git SHA at which they ran. A report from an older SHA remains eligible only
when its complete platform, backup, policy, workflow, restore, and shared lifecycle
source dependencies equal deployed `origin/main`; missing Git objects, comparison
errors, or changed relevant source stop bootstrap. Documentation-only changes do not
invalidate evidence. The newest eligible restore must be newer than the newest eligible
provisioning acceptance.

After confirmation, bootstrap runs a fixed ephemeral PostgreSQL preflight Job with the
existing backup Secret by reference. Its read-only transaction invokes
`platform_operations.read_platform_revision()` and requires revision `026-nocodb-v1`
plus a complete logical backup whose `completed_at` is at or after the revision's
`installed_at`. It repeats this preflight after the parent reconcile and immediately
before NocoDB resume. The Job does not expose a general SQL surface or retrieve Secret
values, and bootstrap removes only the Job with its exact run marker.

Bootstrap then reconciles the parent package,
uses an ownership marker to resume NocoDB, creates or reconciles only the `nocodb`
database and `nocodb_metadata` login, waits for the one NocoDB pod, enables invite-only
signup and restricted workspace creation, and creates the n8n Header Auth credential
named **NocoDB Operator API**. It reads the created credential back by non-secret ID.

The NocoDB Community API token is broad and non-expiring. Bootstrap stores it directly
in n8n and never prints it. A deliberate broad NocoDB-token rotation workflow is not
implemented.

If the client loses the token-create response before n8n stores the token, do not use a
separate recovery command; none exists. Run the same bounded bootstrap again:

```bash
NOCODB_BOOTSTRAP_CONFIRM='bootstrap:nocodb' mise exec -- just bootstrap nocodb
```

With no matching n8n credential, bootstrap may preserve one token with description
`NocoDB Operator API bootstrap/v1`, create one replacement, and report only the orphan's
non-secret ID. Verify the n8n credential, then revoke that reported orphan in NocoDB.
More than one matching orphan is a hard stop; revoke the unexpected tokens through an
attended review before retrying.

On failure, bootstrap re-suspends only the live Kustomization mutation that carries its
ownership marker. It preserves the metadata database, token state, and n8n
credential for diagnosis and retry.

**Expected result:** NocoDB is healthy for attended setup, required application settings
read back as enabled, and n8n has exactly one **NocoDB Operator API** Header Auth
credential. Git still records `nocodb.spec.suspend: true` until all acceptance passes.

### 3. Import and bind the source workflow

In the private n8n editor, import
`kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json`. Create a
Header Auth credential named **NocoDB Source Provisioning Header**. Set its header name
to `Authorization` and its value to `Bearer <token>`, where `<token>` is the retained
bare source-provisioning value. Keep that bare token outside Git for
`NOCODB_SOURCE_PROVISIONING_HEADER` and `NOCODB_SOURCE_PROVISIONING_TOKEN`; the command
and access test add the `Bearer` prefix. Bind:

- **Automation Data Provisioner** to every Postgres node;
- **NocoDB Operator API** to every HTTP Request node; and
- **NocoDB Source Provisioning Header** to **Source Webhook**.

Keep execution order `v1` and all saved manual, successful, failed, and progress
execution data disabled. Publish **NocoDB Source Provisioner** only after checking every
binding. Do not add credential IDs or values to the Git template.

### 4. Adopt one domain

The domain must already be `ready` in automation-data and must have a reviewed
`read_model` schema. A valid domain matches `^[a-z][a-z0-9_]{0,47}$`.

Run the first source sync with the private provisioning header supplied through the
environment or hidden interactive prompt:

```bash
NOCODB_SOURCE_SYNC_CONFIRM='sync:nocodb:<domain>' \
  mise exec -- just kube nocodb-source-sync <domain>
```

NocoDB `2026.08.2` creates sources asynchronously. A successful create request returns a
job ID, not a source. Sync stores that ID, polls the exact job every five seconds for at
most ten minutes, discovers exactly one source only after the job reports `completed`,
reads that source back, checks its schema and edit flags, performs a bounded data read,
and validates PostgreSQL privileges before recording `ready`.

Controlled-edit adoption has two phases:

1. A reviewed domain migration creates the `operator` schema and its intended tables.
   The first sync creates `<domain>_operator` as a `NOLOGIN` grant target. It creates the
   reader source and reports the operator as `awaiting_grants`.
2. A second reviewed domain migration grants that exact `NOLOGIN` role the intended
   table, column, sequence, and optional row-policy authority. Run the same sync command
   again. It validates the catalog, enables only this login, and asynchronously creates
   the operator source.

Source sync never accepts a hostname, database, schema, table, column, grant, or SQL
fragment. More than one deterministic source is a hard stop. An unchanged sync keeps
ready passwords, integrations, source IDs, job IDs, and generations unchanged.

#### Refresh metadata after reviewed additive DDL

After a reviewed domain migration adds a reflected table or column, validate its grants
before opening NocoDB. In the affected base:

1. Open the base settings and select **Data Sources**.
2. Select the exact source alias, then select **Meta Sync**.
3. Select **Reload** and confirm the expected table and additive change. Stop if the
   page reports an unrelated rename, removal, or source.
4. Select **Sync Now**. Wait for **Table metadata recreated successfully**, select
   **Back**, and require **Tables metadata is in Sync**.
5. Run the same `nocodb-source-sync` command again. Require the same base, integration,
   source, credential generation, schema-read-only flag, and saved views.

These labels and the asynchronous metadata-diff behavior are from pinned NocoDB
`2026.08.2`. Disposable API integration proved one additive column with unchanged table,
source, integration, credential, and saved-view identities. An operator must still
perform the attended browser check before this UI procedure counts as live acceptance.

### 5. Rotate one source login

Rotate only the selected PostgreSQL reader or operator login and its matching NocoDB
integration:

```bash
NOCODB_SOURCE_ROTATE_CONFIRM='rotate:nocodb:<domain>:operator' \
  mise exec -- just kube nocodb-source-rotate <domain> operator
```

The final argument must be `reader` or `operator`. Rotation repeats identity and
readiness checks immediately before mutation. The PostgreSQL update keeps the selected
role as `LOGIN` while changing its password. It is convergent, not transactional: an
interruption can temporarily leave PostgreSQL and NocoDB with different credentials.
Retry the same targeted rotation only after the retained base, integration, and source
IDs match.

This command does not rotate `NC_CONNECTION_ENCRYPT_KEY`, the NocoDB administrator, or
the broad NocoDB API token stored in **NocoDB Operator API**.

### 6. Verify observed health

While Git still records `spec.suspend: true`, the default verifier checks the
never-bootstrapped staged state:

```bash
mise exec -- just kube nocodb-verify
```

After an attended workflow deliberately resumes that staged Kustomization, declare the
temporary phase explicitly:

```bash
NOCODB_VERIFY_PHASE=attended mise exec -- just kube nocodb-verify
```

This form requires the live Kustomization and direct Deployment, Helm, Service, route,
policy, and logical-backup observations to be healthy. It does not require the Gatus
endpoint, PrometheusRule, or recurring verification enrollment that remain inactive
until durable activation. The default staged check rejects an active Deployment.

After Git records `spec.suspend: false`, the plain command automatically selects the
durable-active phase. It then also requires the exact Gatus endpoint, Prometheus rules,
and recurring verification enrollment. An absent workload in either attended or durable
active intent is a failure; the verifier does not skip it. All phases are read-only. The
verifier does not read Secrets, authenticate to NocoDB, inspect metadata, invoke source
credentials, or perform a positive authorization probe.

### 7. Run attended access acceptance

Import
`kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json`. Do not bind
a PostgreSQL credential or publish this workflow yet. The first provisioning call must
create `issue334_acceptance` and its generated migrator and runtime credentials. Bind
**NocoDB Operator API** to every HTTP Request node and **NocoDB Acceptance Header** to
**Acceptance Webhook**. NocoDB receives neither PostgreSQL credential. Generate and
retain a separate token with at
least 32 URL-safe characters from `A-Z`, `a-z`, `0-9`, `_`, and `-`. Create the
**NocoDB Acceptance Header** Header Auth credential with header name `Authorization`
and value `Bearer <token>`. Keep the bare token outside Git as
`NOCODB_ACCEPTANCE_TOKEN`. Keep execution persistence disabled. Do not publish the
workflow until both generated PostgreSQL credentials are bound after the first pass.

The access script requires these exact endpoint and token environment variables.
The completed pass also requires the non-secret binding confirmation printed by the
first pass:

| Variable | Required value |
| --- | --- |
| `AUTOMATION_DATA_PROVISIONING_URL` | `https://n8n.lab.supermorphic.com/webhook/automation-data-provision` |
| `NOCODB_SOURCE_PROVISIONING_URL` | `https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source` |
| `NOCODB_ACCEPTANCE_URL` | `https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain` |
| `AUTOMATION_DATA_PROVISIONING_TOKEN` | Bare retained token for **Automation Data Provisioning Header** |
| `NOCODB_SOURCE_PROVISIONING_TOKEN` | Bare retained token used by **NocoDB Source Provisioning Header** |
| `NOCODB_ACCEPTANCE_TOKEN` | Bare retained token used by **NocoDB Acceptance Header** |
| `NOCODB_ACCEPTANCE_BINDING_CONFIRM` | `bound:issue334_acceptance:<generated-migrator-credential-id>:<generated-runtime-credential-id>` |

Each token must contain at least 32 URL-safe characters from the set above. Load all
three tokens through an approved secret-input method and export the exact URLs. Run the
command first without `NOCODB_ACCEPTANCE_BINDING_CONFIRM`. It provisions
`issue334_acceptance`, prints only the two generated non-secret credential IDs, then
stops before it calls the
unpublished acceptance workflow. The catalog records this intentional first pass as
incomplete.

In n8n, bind the generated credentials to these exact PostgreSQL nodes:

| Credential | Nodes |
| --- | --- |
| `automation-data/issue334_acceptance/migrator` | **Create Acceptance Structure**, **Grant Acceptance Access**, **Clear Reader Negative Residue**, **Cleanup Unexpected Reader Insert**, **Clear Feedback Residue**, **Cleanup Feedback Fact** |
| `automation-data/issue334_acceptance/runtime` | **Publish Initial Feedback Fact**, **Consume Feedback Before Refresh**, **Refresh Feedback Fact**, **Consume Feedback After Refresh** |

The migrator nodes perform only reviewed DDL, grants, and bounded residue cleanup. The
runtime nodes publish facts and consume the exact operator decision. Do not bind either
credential to an HTTP Request node. Check all bindings, then publish the workflow. Do not
add either credential ID to the Git template. Rerun the same shell block with the exact
confirmation printed by the first pass:

```bash
(
  export AUTOMATION_DATA_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-provision'
  export NOCODB_SOURCE_PROVISIONING_URL='https://n8n.lab.supermorphic.com/webhook/automation-data-nocodb-source'
  export NOCODB_ACCEPTANCE_URL='https://n8n.lab.supermorphic.com/webhook/nocodb-acceptance-domain'
  printf '%s' 'Automation-data provisioning token: ' >&2
  IFS= read -r -s AUTOMATION_DATA_PROVISIONING_TOKEN
  printf '\n%s' 'NocoDB source-provisioning token: ' >&2
  IFS= read -r -s NOCODB_SOURCE_PROVISIONING_TOKEN
  printf '\n%s' 'NocoDB acceptance token: ' >&2
  IFS= read -r -s NOCODB_ACCEPTANCE_TOKEN
  printf '\n' >&2
  export AUTOMATION_DATA_PROVISIONING_TOKEN NOCODB_SOURCE_PROVISIONING_TOKEN
  export NOCODB_ACCEPTANCE_TOKEN
  export NOCODB_ACCEPTANCE_BINDING_CONFIRM='bound:issue334_acceptance:<generated-migrator-credential-id>:<generated-runtime-credential-id>'
  NOCODB_ACCESS_TEST_CONFIRM='test:nocodb:access' \
    mise exec -- just kube nocodb-access-test
  unset AUTOMATION_DATA_PROVISIONING_TOKEN NOCODB_SOURCE_PROVISIONING_TOKEN
  unset NOCODB_ACCEPTANCE_TOKEN
  unset NOCODB_ACCEPTANCE_BINDING_CONFIRM
)
```

The confirmation guards execution intent. The idempotent provisioning response must
still return the same valid domain and both credential identities before the command
invokes acceptance. The command does not bind, rebind, or publish an n8n workflow.

The completed run provisions the synthetic domain, runs the two-phase source adoption,
proves read and controlled-edit behavior plus PostgreSQL denials, rotates only the
operator source login, demonstrates the complete fact/decision/refresh feedback loop,
and establishes or verifies a persistent record recovery canary. The canary retains fact
ID `-334`, operator `run_id=recovery-canary-v2`, the exact saved-view and source
identities, and this workflow-owned external artifact reference:

```json
{"id":"issue334-artifact-v1","uri":"https://artifacts.example.invalid/issue334/artifact-v1","mediaType":"text/plain","sizeBytes":37,"sha256":"09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3"}
```

The URI is synthetic and is never fetched. Run-owned data rows are removed, but the
synthetic domain, base, sources, registry rows, saved view, and record canary remain for
restore evidence. The workflow never unlocks source schema editing or uses NocoDB-native
uploads, Attachment fields, or comment attachments.

**Expected result:** Both source jobs complete and are discovered and read back; reader
writes and forbidden operator changes are denied by PostgreSQL; unchanged sync is
idempotent; targeted rotation changes only the operator credential generation; the
record canary has exact PostgreSQL, source, table, view, decision-row, and artifact
identity; and feedback reports `original`, `corrected`, `corrected`, `refreshed`, and
`corrected` in sequence. Perform the attended browser check after the API pass: confirm
that the reader is visibly read-only and that the operator can make the intended small
edit.

### 8. Wait for a complete logical backup and run the restore drill

The automation-data logical CronJob runs at `00:30 Etc/UTC`. Wait until one complete,
checksum-valid logical bundle contains the NocoDB metadata, source registry, optional
roles, operator decision, saved view, and synthetic artifact-reference canary.

Then run the attended isolated drill:

```bash
NOCODB_RESTORE_CONFIRM='restore:nocodb:metadata' \
  mise exec -- just kube nocodb-restore-drill
```

The drill selects one complete logical bundle, restores it to an isolated 20 GiB
PostgreSQL claim, and starts NocoDB with fresh ephemeral scratch. It never overwrites the
production database and creates no HTTPRoute. For its full gates and cleanup behavior,
see [Isolated metadata recovery](../runbooks/nocodb-recovery.md#isolated-metadata-recovery).

**Expected result:** Restored metadata, source identities, PostgreSQL grants, saved view,
operator decision, and artifact metadata/reference pass; the isolated restored database
publishes a fresh logical bundle; and all run-owned resources are absent after cleanup.

### 9. Make activation durable only after acceptance

After all prerequisite, access, backup, and restore evidence passes, prepare a reviewed
Git change that sets the NocoDB Flux Kustomization to `spec.suspend: false`. Run the full
repository gate, merge only with explicit operator authorization, and wait for Flux
source parity. Until that change merges, the source of truth remains suspended.

## Routine operation

For normal work:

1. Run `mise exec -- just kube nocodb-verify` before an attended change after durable
   activation. During staged attended activation, use the explicit
   `NOCODB_VERIFY_PHASE=attended` form above.
2. Use `nocodb-source-sync` to add or reconcile one domain.
3. Use a reviewed domain migration between the first and second sync when controlled
   operator editing is required.
4. Use `nocodb-source-rotate` only for explicit, target-bound reader or operator login
   rotation.
5. Confirm that a later complete automation-data logical bundle contains important new
   NocoDB metadata and record/reference state. Recover external artifact bytes through
   their workflow or storage owner.

A NocoDB outage does not block the authoritative domain database or normal n8n
workflows. Do not broaden a NocoDB login to work around an application problem.

## Failure states

- `awaiting_grants` means the operator role exists as `NOLOGIN`; apply the reviewed
  migration and sync again.
- A failed source-creation job remains recorded with its non-secret job and object
  identities. See the recovery runbook before retrying.
- A timed-out job stays `waiting_for_source`. The next explicit sync resumes polling the
  same job; it must not queue another source.
- A failed targeted rotation keeps `operation=rotate` and exact retained identities. Run
  the same explicit rotation only after those identities still match.
- A lost bootstrap token response uses the bounded bootstrap rerun described above.
  There is no separate lost-token recovery command.
- A missing or unreadable `NC_CONNECTION_ENCRYPT_KEY` is a recovery-root failure, not an
  ordinary source rotation.

## Destructive administration

The lifecycle workflows do not delete a NocoDB source, base, registry row, domain, or
PostgreSQL role. Decommissioning requires a separately reviewed, attended procedure with
an explicit target, current ownership and dependency checks, a fresh validated logical
bundle, and immediate precondition checks before each destructive mutation.
