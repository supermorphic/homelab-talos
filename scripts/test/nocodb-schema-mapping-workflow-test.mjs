#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const graph = JSON.parse(readFileSync('kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json', 'utf8'));
const nodes = new Map(graph.nodes.map(node => [node.name, node]));
const invoke = (name, json, context = {}) => new Function('$json', '$', nodes.get(name).parameters.jsCode)(
  json, key => ({ first: () => { if (!(key in context)) throw Error('node not executed'); return { json: context[key] }; } }),
)[0].json;
const request = {domain: 'custom_domain', operation: 'configure', readerSchema: 'reporting', operatorSchema: 'requests'};
assert.deepEqual(invoke('Normalize Source Request', {body: request}), {...request, requestedAccessKind: null});
for (const invalid of [
  {...request, readerSchema: 'public'}, {...request, readerSchema: 'app'},
  {...request, readerSchema: 'read_model'}, {...request, readerSchema: 'operator'},
  {...request, readerSchema: 'a'.repeat(49)},
  {...request, readerSchema: 'platform_reporting'},
  {...request, readerSchema: 'pg_catalog'}, {...request, readerSchema: 'unsafe;sql'},
  {...request, operatorSchema: 'reporting'}, {...request, accessKind: 'reader'},
  {...request, operation: 'sync'}, {...request, role: 'other_reader'},
]) assert.throws(() => invoke('Normalize Source Request', {body: invalid}), `accepted invalid request ${JSON.stringify(invalid)}`);
assert.equal(invoke('Normalize Source Request', {body: {...request, operatorSchema: null}}).operatorSchema, null);

const mapping = {domain: request.domain, readerSchema: 'reporting', operatorSchema: 'requests', readerRole: 'custom_domain_reader', operatorRole: 'custom_domain_operator'};
const response = invoke('Prepare Mapping Response', {result: mapping}, {'Normalize Source Request': request});
assert.deepEqual(response, {ok: true, operation: 'configure', state: 'configured', ...mapping});
for (const bad of [{...mapping, readerSchema: 'other'}, {...mapping, readerRole: 'production_reader'}, {...mapping, unexpected: true}]) {
  assert.throws(() => invoke('Prepare Mapping Response', {result: bad}, {'Normalize Source Request': request}));
}
const route = graph.connections['Configure Requested'].main[0][0].node;
assert.equal(route, 'Configure Schema Mapping');
assert.equal(graph.connections['Configure Schema Mapping'].main[0][0].node, 'Prepare Mapping Response');
assert.equal(graph.connections['Prepare Mapping Response'].main[0][0].node, 'Respond');
assert.equal(nodes.get('Configure Schema Mapping').parameters.query, 'SELECT platform_operations.configure_nocodb_schema_mapping($1, $2, $3) AS result;');

for (const [kind, schema] of [['Reader', 'reporting'], ['Operator', 'requests']]) {
  const key = kind.toLowerCase();
  const context = {domain: request.domain, baseId: 'base-1', sourceId: 'source-1', schema,
    plan: {readerSchema: 'reporting', operatorSchema: 'requests'}, generatedValue: 'synthetic-only'};
  const startName = kind === 'Reader' ? 'Start Reader' : 'Prepare Operator';
  assert.equal(invoke(startName, context).schema, schema);
  assert.equal(invoke(`Merge ${kind} State`, {result: {}}, {[startName]: context}).schema, schema);
  const rotating = {state: 'rotating', sourceId: 'source-1', integrationId: 'integration-1', role: `${request.domain}_${key}`};
  assert.deepEqual(invoke(`Build ${kind} Rotation Integration`, {result: rotating}, {[`Prepare ${kind} Rotation`]: context}).payload.config.searchPath, [schema]);
  const source = {id: 'source-1', base_id: 'base-1', fk_integration_id: 'integration-1', alias: kind === 'Reader' ? 'Read Model' : 'Operator',
    config: {searchPath: [schema]}, is_data_readonly: kind === 'Reader', is_schema_readonly: true};
  const contextNodes = {[startName]: context, [`Read ${kind} State`]: {result: {}},
    [`Discover ${kind} Source`]: {sourceId: 'source-1', selectedIntegrationId: 'integration-1'}};
  assert.equal(invoke(`Validate ${kind} Source`, source, contextNodes).sourceReadBack, true);
  assert.throws(() => invoke(`Validate ${kind} Source`, {...source, config: {searchPath: ['other']}}, contextNodes));
}
console.log('NocoDB custom schema workflow boundaries passed.');
