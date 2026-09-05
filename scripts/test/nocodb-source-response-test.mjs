#!/usr/bin/env node
import assert from 'node:assert/strict';
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const repoRoot = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).stdout.trim();
const workflowPath = join(repoRoot, 'kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json');
const commandPath = join(repoRoot, 'scripts/nocodb/source-operation.sh');
const workflow = JSON.parse(await readFile(workflowPath, 'utf8'));
const responseNode = workflow.nodes.find((node) => node.name === 'Prepare Source Response');
assert(responseNode, 'Prepare Source Response Code node is missing');

const validation = (controlledDmlPresent) => ({
  valid: true,
  loginValid: true,
  schemaPrivilegesValid: true,
  objectPrivilegesValid: true,
  defaultPrivilegesValid: true,
  outsideSchemaDenied: true,
  databaseIsolationValid: true,
  forbiddenAttributesDenied: true,
  forbiddenMembershipsDenied: true,
  ddlDenied: true,
  controlledDmlPresent,
});

const readySource = (accessKind, sourceCreateJobState) => ({
  accessKind,
  state: 'ready',
  sourceId: `source-${accessKind}`,
  integrationId: `integration-${accessKind}`,
  sourceCreateJobId: `job-${accessKind}`,
  sourceCreateJobState,
  sourceDiscovered: true,
  sourceReadBack: true,
  generation: accessKind === 'reader' ? 4 : 6,
  credentialGeneration: accessKind === 'reader' ? 2 : 3,
  operationStartedAt: '2026-09-04T12:00:00Z',
  updatedAt: '2026-09-04T12:01:00Z',
  validatedAt: '2026-09-04T12:01:00Z',
  dataEditAllowed: accessKind === 'operator',
  schemaEditAllowed: false,
  postgresqlValidation: validation(accessKind === 'operator'),
  baseId: 'base-1',
});

const awaitingOperator = {
  accessKind: 'operator',
  state: 'awaiting_grants',
  sourceId: null,
  integrationId: null,
  sourceCreateJobId: null,
  sourceCreateJobState: null,
  sourceDiscovered: false,
  sourceReadBack: false,
  generation: 5,
  credentialGeneration: 0,
  operationStartedAt: '2026-09-04T12:00:00Z',
  updatedAt: '2026-09-04T12:00:00Z',
  validatedAt: null,
  dataEditAllowed: null,
  schemaEditAllowed: null,
  postgresqlValidation: null,
  baseId: 'base-1',
};

const produceResponse = (currentItem, operation) => {
  const lookupNode = (name) => ({
    first: () => ({
      json: name === 'Normalize Source Request'
        ? { domain: 'domain_one', operation, requestedAccessKind: operation === 'rotate' ? 'operator' : null }
        : currentItem.reader,
    }),
  });
  const produce = new Function('$json', '$', responseNode.parameters.jsCode);
  const response = produce(currentItem, lookupNode);
  assert.equal(response.length, 1, 'response producer must return exactly one item');
  return response[0].json;
};

const fixture = await mkdtemp(join(tmpdir(), 'homelab-nocodb-source-response-test.'));
try {
  const binDir = join(fixture, 'bin');
  await mkdir(binDir);
  const gitStub = join(binDir, 'git');
  const curlStub = join(binDir, 'curl');
  await writeFile(gitStub, `#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  status) [[ "\${2:-}" == '--porcelain' ]] ;;
  ls-remote)
    [[ "\${2:-}" == '--exit-code' && "\${3:-}" == origin && "\${4:-}" == refs/heads/main ]]
    printf '%s\\trefs/heads/main\\n' '0123456789012345678901234567890123456789'
    ;;
  cat-file) [[ "\${2:-}" == '-e' ]] ;;
  diff) [[ "\${2:-}" == '--quiet' ]] ;;
  *) exit 64 ;;
esac
`);
  await writeFile(curlStub, `#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == '--config' && -f "$2" ]] || exit 64
config="$2"
body_path="$(awk -F'"' '/^data-binary = / { value=$2; sub(/^@/, "", value); print value; exit }' "$config")"
jq -e --argjson expected "\${NOCODB_SOURCE_RESPONSE_EXPECTED_REQUEST:?}" '. == $expected' "$body_path" >/dev/null
printf '%s\\n' "\${NOCODB_SOURCE_RESPONSE_BODY:?}"
`);
  await Promise.all([chmod(gitStub, 0o700), chmod(curlStub, 0o700)]);

  const invoke = (response, operation = 'sync') => spawnSync(
    commandPath,
    operation === 'rotate' ? ['rotate', 'domain_one', 'operator'] : ['sync', 'domain_one'],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        PATH: `${binDir}:${process.env.PATH}`,
        NOCODB_SOURCE_PROVISIONING_HEADER: 'fixture_nocodb_source_provisioning_header_0123456789',
        NOCODB_SOURCE_SYNC_CONFIRM: 'sync:nocodb:domain_one',
        NOCODB_SOURCE_ROTATE_CONFIRM: 'rotate:nocodb:domain_one:operator',
        NOCODB_SOURCE_RESPONSE_EXPECTED_REQUEST: JSON.stringify(
          operation === 'rotate'
            ? { domain: 'domain_one', operation: 'rotate', accessKind: 'operator' }
            : { domain: 'domain_one', operation: 'sync' },
        ),
        NOCODB_SOURCE_RESPONSE_BODY: JSON.stringify(response),
      },
    },
  );

  const cases = [
    {
      name: 'reader-only initial creation',
      operation: 'sync',
      current: { reader: readySource('reader', 'completed'), operator: null },
    },
    {
      name: 'reader ready with operator awaiting grants',
      operation: 'sync',
      current: { reader: readySource('reader', null), operator: awaitingOperator },
    },
    {
      name: 'both sources ready after job history expires',
      operation: 'sync',
      current: { reader: readySource('reader', null), operator: readySource('operator', null) },
    },
    {
      name: 'targeted rotation after job history expires',
      operation: 'rotate',
      current: { reader: readySource('reader', null), operator: readySource('operator', null) },
    },
  ];

  const produced = new Map();
  for (const testCase of cases) {
    const response = produceResponse(testCase.current, testCase.operation);
    produced.set(testCase.name, response);
    const result = invoke(response, testCase.operation);
    assert.equal(result.status, 0, `${testCase.name} failed shell validation: ${result.stderr}`);
    assert.deepEqual(JSON.parse(result.stdout), response, `${testCase.name} was not returned unchanged`);
  }

  const missingField = structuredClone(produced.get('both sources ready after job history expires'));
  delete missingField.reader.validatedAt;
  const missingResult = invoke(missingField);
  assert.notEqual(missingResult.status, 0, 'response missing a bounded source field was accepted');

  const wrongType = structuredClone(produced.get('targeted rotation after job history expires'));
  wrongType.operator.credentialGeneration = '4';
  const wrongTypeResult = invoke(wrongType, 'rotate');
  assert.notEqual(wrongTypeResult.status, 0, 'response with a wrong bounded source field type was accepted');
} finally {
  await rm(fixture, { recursive: true, force: true });
}

console.log('NocoDB source response boundary tests passed.');
