# NocoDB operations

This guide stages and operates the private NocoDB interface for selected
automation-data PostgreSQL domains. NocoDB is an optional operator interface. PostgreSQL
remains the authority boundary, and n8n remains the workflow and bulk-change boundary.

The activation change sets the NocoDB Flux Kustomization to `spec.suspend: false`
and enrolls Homepage, Gatus, alerts, and recurring verification together. On 2026-09-09,
the operator completed bootstrap, source provisioning, access acceptance, and the browser
check. The successful access run is
`20260909T181605Z-3d4e74fd0a3c-operator-0b9528a0`.

On 2026-09-09, the operator authorized durable activation after successful access and
browser acceptance, with the isolated restore drill as the final rollout step. The human
operator reviews and merges the activation change. Verify activation, then complete the
drill using a post-acceptance logical backup. That rollout drill passed on 2026-09-10.
The replacement-domain drill passed again on 2026-09-23; see the implementation status
in [specification 028](../specs/028-nocodb-operator-ui.md).

Use [Staged activation](#staged-activation) for the first deployment and
[Routine operation](#routine-operation) afterward. Use [Failure states](#failure-states)
for day-2 decisions and the
[platform recovery section](../runbooks/platform-disaster-recovery.md#nocodb-metadata-recovery)
for recovery roots and the key-loss boundary.

## Before you start

For a first installation, stage the NocoDB Kustomization with `spec.suspend: true`
and leave monitoring and verification unenrolled until the attended steps pass.
Start the attended rollout only when all of these conditions are true:

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

For registered application logins, also retain the protected client credential
directory described in [automation-data operations](automation-data-operations.md#registered-application-logins-and-private-cli-access).
The database backup holds the verifier, not a recoverable plaintext client password.

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
retain the Git SHA at which they ran. The publisher rejects dirty checkouts. Bootstrap
accepts passed published runs from deployed main or its ancestors, including reports
marked as candidates because main advanced before publication. The dashboard's
`authoritative` flag does not determine bootstrap eligibility.
A report from an older SHA remains eligible only
when its complete platform, backup, policy, workflow, restore, and shared lifecycle
source dependencies equal deployed `origin/main`; missing Git objects, comparison
errors, or changed relevant source stop bootstrap. Documentation-only changes do not
invalidate evidence. The newest eligible restore must be newer than the newest eligible
provisioning acceptance.

After confirmation, bootstrap checks that the reviewed NocoDB platform extension
is installed and that a complete logical backup was taken afterward. If it rejects
the installed platform functions, run the guarded automation-data upgrade from
deployed main, create and verify a fresh complete backup, and renew any affected
provisioning or restore evidence before retrying bootstrap. Stop on a failed
preflight; do not repair platform metadata manually.

Bootstrap then reconciles the parent package,
uses an ownership marker to resume NocoDB, creates or reconciles only the `nocodb`
database and `nocodb_metadata` login, waits for the one NocoDB pod, enables invite-only
signup and restricted workspace creation, and creates the n8n Header Auth credential
named **NocoDB Operator API**. It reads the created credential back by non-secret ID.

The `automation-data` namespace carries `gateway.supermorphic.com/access: internal`
so Envoy Gateway watches its HTTPRoute. ExternalDNS publishes the accepted internal
route to Pi-hole. After rollout, bootstrap waits for route acceptance and resolved
references, checks their current generation, then retries DNS lookup failures up to
13 times with ten-second intervals. Other health failures stop immediately. These
checks finish before bootstrap reads administrator credentials or calls sign-in.

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

Suspension does not stop an already-created Deployment or its HelmRelease. The metadata
Job and application still reconcile in the same package, so a failed bootstrap can
leave the application running before API setup completes.

On a confirmed retry, after preflight succeeds and while NocoDB is suspended, bootstrap
removes only a terminally failed `nocodb-metadata-bootstrap` Job with the expected Flux
labels. UID and resource-version preconditions reject concurrent changes. Foreground
deletion removes its dependent pods, and Flux recreates the Job on resume. Successful
Jobs are retained. Active, terminating, or unexpectedly owned failed Jobs stop the retry.
Collect needed failed-Job diagnostics before retrying.

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

### Configure a domain with custom NocoDB schemas

Use this only when a ready domain needs a NocoDB-facing schema name other than
the standard `read_model` or `operator`.

1. Configure the permanent mapping:

   ```bash
   NOCODB_SOURCE_CONFIGURE_CONFIRM='configure:nocodb:<domain>:<reader>:<operator>' \
     mise exec -- just kube nocodb-source-configure <domain> <reader> <operator>
   ```

   Use `-` for `<operator>` when no operator schema is required. A successful
   response records the mapping and returns the generated reader role name and,
   when applicable, the operator role name. The mapping cannot be changed for
   this domain.

2. Apply the domain's reviewed migration to grant those roles their intended access.
3. Run the guarded source prepare and sync commands in steps 4 and 5 below.

If configuration conflicts with an existing mapping or source, stop. If source
preparation or sync reports a privilege mismatch, stop and fix the domain
migration. Do not change grants manually to make provisioning pass.

See [Spec 028](../specs/028-nocodb-operator-ui.md) for the role-isolation,
privilege-validation, backup/restore, and mapping design.

### 4. Prepare domain access without NocoDB registration

The domain must already be `ready` in automation-data and must have a reviewed
`read_model` schema or its configured custom reader schema. A valid domain matches
`^[a-z][a-z0-9_]{0,47}$`. Supply the existing
private source-provisioning header through the environment or hidden interactive prompt:

```bash
NOCODB_SOURCE_PREPARE_CONFIRM='prepare:nocodb:<domain>' \
  mise exec -- just kube nocodb-source-prepare <domain>
```

This authenticated operation creates or validates the restricted `<domain>_reader`
role. A new role starts as `NOLOGIN`. If an `operator` schema exists, it also creates or
validates `<domain>_operator`; missing reviewed controlled-edit grants can create an
identity-free `awaiting_grants` registry row. Preparation is limited to initial role
setup: it requires no reader registry row and permits only an absent operator row or the
identity-free `awaiting_grants` candidate created by an earlier prepare call. It refuses
`provisioning`, `waiting_for_source`, `ready`, `rotating`, and `error` source states.

Use source sync for registered sources and targeted rotation for credential changes.
Do not use prepare as source repair or deactivation.

The bounded response reports the canonical roles and reader/operator eligibility. It
does not generate a password or return a base, integration, or source ID. It does not
call NocoDB, create a base, register a source, or make a role available for login.

### 5. Adopt one domain

The domain must already be `ready` in automation-data and must have a reviewed
`read_model` schema or its configured custom reader schema. A valid domain matches
`^[a-z][a-z0-9_]{0,47}$`.

Run the first source sync with the private provisioning header supplied through the
environment or hidden interactive prompt:

```bash
NOCODB_SOURCE_SYNC_CONFIRM='sync:nocodb:<domain>' \
  mise exec -- just kube nocodb-source-sync <domain>
```

Source creation can complete asynchronously. Wait for source sync to report `ready`.
If it fails or remains pending, inspect the reported job or source state before
retrying.

Standard controlled-edit adoption has two phases:

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

Confirm these screen labels in the deployed NocoDB interface. The attended
browser check is required before this procedure counts as live acceptance.

### 6. Rotate one source login

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

### 7. Verify observed health

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

### 8. Run attended access acceptance

Platform provisioning acceptance and NocoDB acceptance use the fixed
`automation_data_acceptance` domain. The platform phase installs no application tables,
so the NocoDB fixture can add its reviewed acceptance structure to the same domain.

Import
`kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json`. Do not bind
a PostgreSQL credential or publish this workflow yet. The first provisioning call must
create or reconcile `automation_data_acceptance` and return its stable generated
migrator and runtime credentials.
Bind **NocoDB Operator API** to every HTTP Request node and **NocoDB Acceptance Header**
to **Acceptance Webhook**. NocoDB receives neither PostgreSQL credential. Generate and
retain a separate token with at least 32 URL-safe characters from `A-Z`, `a-z`, `0-9`,
`_`, and `-`. Create the
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
| `NOCODB_ACCEPTANCE_BINDING_CONFIRM` | `bound:automation_data_acceptance:<generated-migrator-credential-id>:<generated-runtime-credential-id>` |

Each token must contain at least 32 URL-safe characters from the set above. Load all
three tokens through an approved secret-input method and export the exact URLs. Run the
command first without `NOCODB_ACCEPTANCE_BINDING_CONFIRM`. It provisions
`automation_data_acceptance`, prints only the two generated non-secret credential IDs,
then stops before it calls the unpublished acceptance workflow. The catalog records this
intentional first pass as incomplete.

In n8n, bind the generated credentials to these exact PostgreSQL nodes:

| Credential | Nodes |
| --- | --- |
| `automation-data/automation_data_acceptance/migrator` | **Create Acceptance Structure**, **Grant Acceptance Access**, **Clear Reader Negative Residue**, **Cleanup Unexpected Reader Insert**, **Clear Feedback Residue**, **Cleanup Feedback Fact**, **Grant Extended Acceptance Access**, **Cleanup Extended Acceptance** |
| `automation-data/automation_data_acceptance/runtime` | **Publish Initial Feedback Fact**, **Consume Feedback Before Refresh**, **Refresh Feedback Fact**, **Consume Feedback After Refresh** |

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
  export NOCODB_ACCEPTANCE_BINDING_CONFIRM='bound:automation_data_acceptance:<generated-migrator-credential-id>:<generated-runtime-credential-id>'
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
`corrected` in sequence. Each access probe checks deletion of its exact decision row.
The feedback decision remains available through the post-rotation probe and is removed
by the final run cleanup. Perform the attended browser check after the API pass: confirm
that the reader is visibly read-only and that the operator can make the intended small
edit.

### 9. Make activation durable after access acceptance

After platform prerequisites, access acceptance, and the browser check pass, complete
review of the activation change under the operator-approved rollout sequence. It sets
the NocoDB Flux Kustomization to `spec.suspend: false`, adds the Homepage
**Platform → NocoDB** tile, enables the Gatus **Automation → nocodb** health endpoint
and NocoDB alert rules, and enrolls `verification.nocodb` in both verification campaigns.
Homepage discovers the tile from the NocoDB HTTPRoute; it needs no API credential.

Follow the [contributor workflow](repository-worktree-setup.md#prepare-validate-and-publish-a-change).
The human operator reviews and merges the PR, then waits for Flux source parity. Then run
`mise exec -- just kube nocodb-verify`, confirm the Homepage link opens the private UI,
and confirm the Gatus NocoDB endpoint is healthy. Record and publish the final evidence.
After activation verification, complete the backup and restore step below. Do not
claim recoverability or close the rollout issue until the isolated drill passes.

### 10. Wait for a complete logical backup and run the restore drill

The automation-data logical CronJob runs at `00:30 Etc/UTC`. Wait until one complete,
checksum-valid logical bundle contains the NocoDB metadata, source registry, optional
roles, operator decision, saved view, and synthetic artifact-reference canary.

Then run the attended isolated drill:

```bash
NOCODB_RESTORE_CONFIRM='restore:nocodb:metadata' \
  mise exec -- just kube nocodb-restore-drill
```

The drill proves one complete logical bundle can recover NocoDB metadata without
overwriting production state. The guarded workflow and tests own its exact validation,
isolation, and cleanup behavior.

**Expected result:** Restored metadata, source identities, PostgreSQL grants, saved view,
operator decision, and artifact metadata/reference pass; the isolated restored database
publishes a fresh logical bundle; and all run-owned resources are absent after cleanup.

### 11. Record acceptance for additional pairs and application logins

After deploying v3 and binding the two extended migrator nodes listed above, select the
source-pair extension for issue 491. The baseline commands still cover the original pair;
a baseline result does not prove the new application credential contract.

Create a private credential directory outside the checkout, with mode `0700`, and set
`AUTOMATION_DATA_LOGIN_DIRECTORY` to its absolute path. Keep it for rotation and recovery.
Use the approved scoped kubeconfig and the endpoint, token, and binding inputs from step 7.
The extension registers only the synthetic domain's `extra` pair (`extra_read`/`extra_edit`)
and its separate `interview` application login in `app`. It installs fixed synthetic grants,
synchronizes and rotates only the named operator, checks retained default identities, and
probes the application through the private PostgreSQL tunnel. It verifies permitted function
writes and reads, and PostgreSQL denials for withheld tables/functions, direct table writes,
cross-pair reads, and assuming the owner role. Repeated runs retain the application credential;
a ready login requires its existing protected profile.

With explicit authority for this attended synthetic mutation, record the extended run:

```bash
NOCODB_ACCESS_TEST_CONFIRM='test:nocodb:access' \
NOCODB_ACCESS_EXTENSION_CONFIRM='test:nocodb:access:source-pairs-v3' \
  mise exec -- just test record test.nocodb-access
```

Complete the separate attended Community Edition browser checks for ordinary fields,
linked records, and saved views. Take a fresh complete backup after the extended access
run, retaining the selected application credential. Select a bundle that contains both
pairs and that credential generation, then record the isolated restore:

```bash
NOCODB_RESTORE_CONFIRM='restore:nocodb:metadata' \
NOCODB_RESTORE_EXTENSION_CONFIRM='restore:nocodb:source-pairs-v3' \
  mise exec -- just test record test.nocodb-restore-drill
```

The extension authenticates with the retained application credential in a separate client
Job after the isolated network policy passes independent validation. It checks the same
positive operations and actual PostgreSQL denial codes. It creates a run-owned temporary
credential Secret, uses only the isolated database Service, and verifies removal of the
Secret and Job during cleanup. Private credential manifests remain outside test reports.
Catalog validation of application grants alone is not authenticated recovery evidence.

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

- If only the NocoDB pod fails while automation-data PostgreSQL remains healthy, let
  the Deployment replace it and run `mise exec -- just kube nocodb-verify`. Its local
  scratch is disposable; a pod replacement does not require a metadata restore.
- `awaiting_grants` means the operator role exists as `NOLOGIN`; apply the reviewed
  migration and sync again.
- A timed-out source job stays `waiting_for_source`. Run the same confirmed
  [source sync](#5-adopt-one-domain) to resume its stored job; do not start another
  source generation.
- A failed or partial source creation retains its job, base, integration, source,
  role, and generation identity. Inspect the recorded state and any surviving source
  before a reviewed retry. Do not automatically delete or adopt a partial source.
- If bootstrap loses the API-token response, rerun the same guarded
  [bootstrap](#2-bootstrap-nocodb-and-its-n8n-api-credential). Do not manually create
  a replacement token.
- A failed targeted rotation keeps `operation=rotate` and exact retained identities.
  PostgreSQL and NocoDB credentials may temporarily differ. Verify the base,
  integration, and source IDs, then use the same target's
  [attended retry](#targeted-rotation-and-attended-retry). Ordinary sync and rotation of the
  other access kind remain blocked while this error is recorded.
- A missing or unreadable `NC_CONNECTION_ENCRYPT_KEY` is a hard stop for ordinary
  recovery; prepare a separately reviewed recovery design.

## Add an independent source pair

This requires the deployed v3 control extension and reviewed workflow revision.
Issue 491's candidate does not authorize production registration, grants, or rotation.
Use the existing ready domain; do not create another domain alias for its database.
The following names are synthetic.

1. Register immutable schema mappings and capture the returned `readerRole` and
   `operatorRole`. Registration creates restricted `NOLOGIN` grant targets:

   ```bash
   NOCODB_PAIR_REGISTER_CONFIRM='register:nocodb:sample:extra:extra_read:extra_edit' \
     mise exec -- just kube nocodb-pair-register sample extra extra_read extra_edit
   ```

   A pair matches `^[a-z][a-z0-9_]{0,23}$`; `default` is reserved for existing
   domain-only calls. Reader/operator schemas must differ. Use `-` in the operator
   argument for a reader-only pair. Roles are returned as
   `nocodb_<md5(domain + ':' + pair)>_reader` and its `_operator` sibling.

2. Apply consumer-reviewed migrations through a separate migrator credential.
   Grant each returned role `CONNECT` to the domain database, `USAGE` on its mapped
   schema, and only the intended object permissions. Grant reader `SELECT` on
   presentation objects and operator only the approved native editing permissions.
   Withhold bookkeeping tables and privileged functions, even inside those schemas.
   The platform supplies no application tables or automatic consumer grants.

3. Prepare and inspect eligibility before sync:

   ```bash
   NOCODB_PAIR_PREPARE_CONFIRM='prepare:nocodb:sample:extra' \
     mise exec -- just kube nocodb-pair-prepare sample extra
   NOCODB_PAIR_SYNC_CONFIRM='sync:nocodb:sample:extra' \
     mise exec -- just kube nocodb-pair-sync sample extra
   ```

   Preparation validates effective privileges. Sync creates the named base
   `sample--extra`, separate integrations, and the asynchronous sources. It rejects
   unrelated objects with matching titles. Preserve returned base, integration, and
   source IDs. Pending or failed responses do not establish readiness.

4. Repeat sync to validate the same identities and credentials. For new columns or
   tables, use the supported NocoDB metadata refresh described under routine
   operation, then sync. Adding a pair or refreshing it preserves the default pair,
   other pairs, their credential generations, and saved views.

5. Register the separate application login using the
   [private CLI procedure](automation-data-operations.md#registered-application-logins-and-private-cli-access).
   Consumer acceptance must still prove ordinary Community Edition fields and linked
   records, application reads/writes, stale-revision rejection, and private export.

### Targeted rotation and attended retry

Rotate one source after verifying its current identity:

```bash
NOCODB_PAIR_ROTATE_CONFIRM='rotate:nocodb:sample:extra:reader' \
  mise exec -- just kube nocodb-pair-rotate sample extra reader
```

This preserves source IDs and changes only the selected credential. Domain-only
`nocodb-source-prepare`, `nocodb-source-sync`, and `nocodb-source-rotate` retain their
existing meaning for the default pair.

A partial rotation retains its operation claim and source identities. Ordinary sync
cannot generate a replacement password. Retry requires attended confirmation that the
previous workflow has ended and its NocoDB requests have completed or been cancelled.
A timeout, a stopped client, or elapsed time alone is insufficient. If this condition
cannot be established through authorized administration, retain the claim and stop.

Read the retained operation without changing sources or credentials:

```bash
mise exec -- just kube nocodb-pair-status sample extra
# For the original pair: mise exec -- just kube nocodb-source-status sample
```

The bounded response contains `claim.operationId`, `phase`, operation, access kind,
and generation, or a null claim when no operation was retained. A phase of `uncertain`
is not proof that previous external requests have ended. After independently establishing
quiescence, use the exact retained operation ID; never invent one:

```bash
# Synthetic ID: substitute the retained, confirmed-quiescent operation ID.
NOCODB_PAIR_RETRY_CONFIRM='retry:nocodb:sample:extra:reader:00000000-0000-4000-8000-000000000493:quiesced' \
  mise exec -- just kube nocodb-pair-retry sample extra reader \
    00000000-0000-4000-8000-000000000493
```

For the default pair, use `nocodb-source-retry <domain> <access-kind> <operation-id>`
and `NOCODB_SOURCE_RETRY_CONFIRM='retry:nocodb:<domain>:<access-kind>:<operation-id>:quiesced'`.
The authenticated retry request carries `quiescedOperationId`; SQL rejects a stale ID,
active claim, different target, or missing durable source identity. This confirmation
is an execution guard; it does not grant authority for live credential mutation.

Lost create responses remain an observation or attended reconciliation case. Do not
clear registry rows, create replacement objects, or replay a create because its job
history is missing. The disposable fixture proves that concurrent sync and observation
preserve the accepted source and credential generation after a lost API response.

## Destructive administration

The lifecycle workflows do not delete a NocoDB source, base, registry row, domain, or
PostgreSQL role. Decommissioning requires a separately reviewed, attended procedure
for one explicit target. Identify its current owners, registry rows, source objects,
credentials, and consumers; protect a fresh complete logical bundle and matching n8n
recovery material. Repeat identity, ownership, dependency, backup, and concurrency
checks immediately before each destructive step, then verify the result.

If a decommission stops partway through, preserve the completed-step record and all
surviving objects. Freeze further deletion until an operator reviews the current
identities and remaining steps. Do not infer completion from one missing object or
delete additional objects as automatic compensation. Validate a new complete bundle
after an authorized decommission finishes.
