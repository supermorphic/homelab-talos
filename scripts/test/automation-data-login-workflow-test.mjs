#!/usr/bin/env node
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const graph = JSON.parse(readFileSync(
  'kubernetes/apps/automation/n8n/app/workflows/automation-data-provisioner.json', 'utf8'));
const nodes = new Map(graph.nodes.map(node => [node.name, node]));
const invoke = (name, body, result = null) => new Function('$json', '$',
  nodes.get(name).parameters.jsCode)({body, result}, () => ({first: () => ({json: body})}))[0].json;
const id = '00000000-0000-4000-8000-000000000201';
const cases = [
  {operation: 'login-register', application: 'interview', schema: 'interview_api'},
  {operation: 'login-activate', application: 'interview', operationId: id,
    expectedGeneration: 0, password: 'synthetic-password-with-at-least-32-chars'},
  {operation: 'login-validate', application: 'interview'},
  {operation: 'login-rotate', application: 'interview', operationId: id,
    expectedGeneration: 1, password: 'synthetic-password-with-at-least-32-chars'},
  {operation: 'login-complete', application: 'interview', operationId: id,
    credentialGeneration: 1},
];
const names = ['Register Application Login', 'Install Application Login',
  'Read Application Login', 'Rotate Application Login', 'Complete Application Login'];
for (const [index, input] of cases.entries()) {
  const request = {domain: 'sample', ...input};
  assert.deepEqual(invoke('Normalize Request', request), request);
  assert.equal(graph.connections['Select Operation'].main[index + 4][0].node, names[index]);
}
// Retirement is appended so the existing output indexes stay stable.
const retireRequest = {domain: 'sample', operation: 'login-retire', application: 'interview'};
assert.deepEqual(invoke('Normalize Request', retireRequest), retireRequest);
assert.equal(graph.connections['Select Operation'].main[9][0].node, 'Retire Application Login');
assert.equal(nodes.get('Retire Application Login').parameters.query,
  'SELECT platform_operations.retire_application_login($1, $2) AS result;');
assert.equal(graph.connections['Retire Application Login'].main[1][0].node, 'Prepare Error Response');
for (const extra of [{password: 'synthetic-password-with-at-least-32-chars'},
  {operationId: id}, {schema: 'interview_api'}, {expectedGeneration: 0}]) {
  assert.throws(() => invoke('Normalize Request', {...retireRequest, ...extra}));
}
const login = {domain: 'sample', application: 'interview', database: 'sample',
  schema: 'interview_api', role: `app_${'0'.repeat(32)}_integration`,
  credentialGeneration: 2, operationId: null, operation: null, expectedGeneration: null};
const respond = (result) => invoke('Prepare Application Response', retireRequest, result);
assert.deepEqual(respond({...login, state: 'retired'}), {ok: true, domain: 'sample',
  operation: 'login-retire', application: 'interview', database: 'sample',
  schema: 'interview_api', role: login.role, state: 'retired', credentialGeneration: 2,
  operationId: null, expectedGeneration: null});
assert.deepEqual(respond({...login, state: 'ready', errorCode: 'application_login_still_granted',
  failedChecks: ['objectPrivilegesValid', 'schemaPrivilegesValid']}), {ok: false,
  domain: 'sample', operation: 'login-retire', application: 'interview',
  errorCode: 'application_login_still_granted',
  failedChecks: ['objectPrivilegesValid', 'schemaPrivilegesValid']});
for (const code of ['application_login_in_use', 'application_operation_active']) {
  assert.equal(respond({...login, state: 'ready', errorCode: code, failedChecks: []}).errorCode, code);
}
for (const unsafe of [{errorCode: 'raw database detail', failedChecks: []},
  {errorCode: 'application_login_still_granted', failedChecks: ['unknownCheck']},
  {errorCode: 'application_login_still_granted', failedChecks: 'schemaPrivilegesValid'}]) {
  assert.throws(() => respond({...login, state: 'ready', ...unsafe}));
}
assert.throws(() => invoke('Prepare Application Response',
  {domain: 'sample', operation: 'login-validate', application: 'interview'},
  {...login, state: 'ready', errorCode: 'application_login_in_use', failedChecks: []}));
for (const extra of [
  {host: 'foreign'}, {database: 'foreign'}, {role: 'postgres'}, {sql: 'SELECT 1'},
]) assert.throws(() => invoke('Normalize Request', {domain: 'sample', ...cases[0], ...extra}));
for (const invalid of [
  {operation: 'login-validate', application: 'interview', password: 'synthetic-secret'},
  {operation: 'login-activate', application: 'interview', operationId: id,
    expectedGeneration: 0},
  {operation: 'login-rotate', application: 'interview', operationId: 'not-a-uuid',
    expectedGeneration: 1, password: 'synthetic-password-with-at-least-32-chars'},
  {operation: 'login-complete', application: 'interview', operationId: id},
]) assert.throws(() => invoke('Normalize Request', {domain: 'sample', ...invalid}));
for (const name of [...names, 'Retire Application Login']) {
  assert.match(nodes.get(name).parameters.options.queryReplacement, /Normalize Request/);
  assert.equal(graph.connections[name].main[0][0].node, 'Prepare Application Response');
}
assert.equal(graph.settings.saveDataSuccessExecution, 'none');
assert.equal(graph.settings.saveDataErrorExecution, 'none');
assert.equal(graph.settings.saveExecutionProgress, false);
console.log('Application login workflow boundary tests passed.');
