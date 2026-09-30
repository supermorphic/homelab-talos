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
for (const [index, input] of cases.entries()) {
  const request = {domain: 'sample', ...input};
  assert.deepEqual(invoke('Normalize Request', request), request);
  assert.equal(graph.connections['Select Operation'].main[index + 4][0].node,
    ['Register Application Login', 'Install Application Login',
      'Read Application Login', 'Rotate Application Login',
      'Complete Application Login'][index]);
}
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
for (const name of ['Register Application Login', 'Install Application Login',
  'Read Application Login', 'Rotate Application Login', 'Complete Application Login']) {
  assert.match(nodes.get(name).parameters.options.queryReplacement, /Normalize Request/);
  assert.equal(graph.connections[name].main[0][0].node, 'Prepare Application Response');
}
assert.equal(graph.settings.saveDataSuccessExecution, 'none');
assert.equal(graph.settings.saveDataErrorExecution, 'none');
assert.equal(graph.settings.saveExecutionProgress, false);
console.log('Application login workflow boundary tests passed.');
