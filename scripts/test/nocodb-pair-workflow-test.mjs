#!/usr/bin/env node
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const graph = JSON.parse(readFileSync(
  'kubernetes/apps/automation/n8n/app/workflows/nocodb-source-provisioner.json', 'utf8'));
const nodes = new Map(graph.nodes.map(node => [node.name, node]));
const invoke = (name, json, context = {}, errorBranch = false) => new Function('$json', '$', '$input',
  nodes.get(name).parameters.jsCode)(json, key => ({ first: branch => {
    if (!(key in context)) throw Error('node not executed');
    // n8n selects the connecting output by default. On an error path, the
    // normalized request is on output 0, while output 1 contains the error.
    if (errorBranch && key === 'Normalize Source Request' && branch !== 0)
      return {json: {error: 'upstream_error'}};
    return { json: context[key] };
  } }), {all: () => []})[0].json;

const registration = {domain: 'sample', pair: 'interviews', operation: 'register',
  readerSchema: 'extra_read', operatorSchema: 'extra_edit'};
const normalized = invoke('Normalize Source Request', {body: registration});
assert.deepEqual(normalized, {...registration, requestedAccessKind: null});
for (const invalid of [
  {...registration, pair: 'default'}, {...registration, pair: 'a'.repeat(25)},
  {...registration, pair: 'Bad'}, {...registration, unexpected: true},
  {...registration, readerSchema: 'public'},
]) assert.throws(() => invoke('Normalize Source Request', {body: invalid}));

const legacy = invoke('Normalize Source Request', {body: {domain: 'sample', operation: 'sync'}});
assert.deepEqual(legacy, {domain: 'sample', operation: 'sync', requestedAccessKind: null});
const named = invoke('Normalize Source Request', {body: {
  domain: 'sample', pair: 'interviews', operation: 'rotate', accessKind: 'reader'}});
assert.equal(named.pair, 'interviews');
assert.equal(named.accessKind, 'reader');
assert.equal(named.requestedAccessKind, 'reader');
assert.throws(() => invoke('Normalize Source Request', {body: {
  domain: 'sample', pair: 'interviews', operation: 'retry', accessKind: 'operator'}}),
  /quiesced_operation_required/);
const previousOperation = '00000000-0000-4000-8000-000000000493';
const retry = invoke('Normalize Source Request', {body: {
  domain: 'sample', pair: 'interviews', operation: 'retry', accessKind: 'operator',
  quiescedOperationId: previousOperation}});
assert.equal(retry.operation, 'rotate');
assert.equal(retry.quiescedOperationId, previousOperation);
assert.equal(retry.requestedAccessKind, 'operator');
assert.throws(() => invoke('Normalize Source Request', {body: {
  domain: 'sample', pair: 'interviews', operation: 'retry'}}));
const failedPair = invoke('Prepare Source Error Response', {error: 'bounded_failure'},
  {'Normalize Source Request': {domain: 'sample', pair: 'interviews', operation: 'sync'}}, true);
assert.equal(failedPair.ok, false);
assert.equal(failedPair.domain, 'sample');
assert.equal(failedPair.pair, 'interviews');
assert.equal(failedPair.operation, 'sync');

assert.equal(graph.connections['Register Requested'].main[0][0].node,
  'Register NocoDB Pair');
assert.equal(nodes.get('Register NocoDB Pair').parameters.query,
  'SELECT platform_operations.configure_nocodb_pair($1, $2, $3, $4) AS result;');
assert.equal(nodes.get('Prepare NocoDB Access').parameters.query,
  'SELECT platform_operations.prepare_nocodb_access($1, $2) AS result;');
assert.equal(nodes.get('Claim Source Operation').parameters.query,
  'SELECT platform_operations.claim_nocodb_operation($1, $2, $3, $4, gen_random_uuid(), $5) AS result;');
assert.match(nodes.get('Claim Source Operation').parameters.options.queryReplacement,
  /\$json\.quiescedOperationId \|\| null/);
assert.equal(nodes.get('Mark Claim Uncertain').parameters.query,
  'SELECT platform_operations.mark_nocodb_operation_uncertain($1, $2, $3, $4, $5) AS result;');
for (const mutation of ['Create Domain Base', 'Create Reader Integration',
  'Create Reader Source', 'Rotate Reader Credential', 'Patch Reader Rotation Integration',
  'Create Operator Integration', 'Create Operator Source',
  'Rotate Operator Credential', 'Patch Operator Rotation Integration']) {
  assert.equal(graph.connections[mutation].main[1][0].node, 'Mark Claim Uncertain');
}

const hash = 'a'.repeat(32);
const registered = invoke('Prepare Registration Response', {result: {
  domain: 'sample', pair: 'interviews', readerSchema: 'extra_read',
  operatorSchema: 'extra_edit', readerRole: `nocodb_${hash}_reader`,
  operatorRole: `nocodb_${hash}_operator`,
}}, {'Normalize Source Request': normalized});
assert.deepEqual(Object.keys(registered).sort(), [
  'domain', 'ok', 'operation', 'operatorRole', 'operatorSchema', 'pair',
  'readerRole', 'readerSchema', 'state']);
assert.throws(() => invoke('Prepare Registration Response', {result: {
  ...registered, readerRole: 'another_role',
}}, {'Normalize Source Request': normalized}));

const preparedRequest = invoke('Normalize Source Request', {body: {
  domain: 'sample', pair: 'interviews', operation: 'prepare'}});
const plan = {domain: 'sample', pair: 'interviews', readerSchema: 'extra_read',
  operatorSchema: 'extra_edit', readerRole: `nocodb_${hash}_reader`,
  operatorRole: `nocodb_${hash}_operator`, readerEligible: false,
  operatorRequested: true, operatorEligible: false};
const keptPlan = invoke('Keep Access Plan', {result: plan},
  {'Normalize Source Request': preparedRequest});
const pending = invoke('Prepare Access Response', keptPlan,
  {'Normalize Source Request': preparedRequest});
assert.equal(pending.pair, 'interviews');
assert.equal(pending.readerEligible, false);
assert.throws(() => invoke('Keep Access Plan', {result: plan},
  {'Normalize Source Request': {...preparedRequest, operation: 'sync'}}));

const context = {domain: 'sample', pair: 'interviews', operation: 'sync',
  requestedAccessKind: null, plan: {...plan, readerEligible: true}};
const claim = {domain: 'sample', pair: 'interviews', operation: 'sync',
  accessKind: null, operationId: '00000000-0000-4000-8000-000000000123',
  generation: 4, phase: 'active', canExecute: true};
const claimed = invoke('Keep Source Claim', {result: claim},
  {'Keep Access Plan': context});
assert.equal(claimed.claim.canExecute, true);
assert.throws(() => invoke('Keep Source Claim', {result: {...claim, pair: 'other'}},
  {'Keep Access Plan': context}));

const baseContext = {'Keep Source Claim': claimed,
  'Read Base Registry': {result: null}};
const newBase = invoke('Resolve Domain Base', {list: []}, baseContext);
assert.equal(newBase.createBase, true);
assert.throws(() => invoke('Resolve Domain Base', {list: [
  {id: 'foreign-base', title: 'sample--interviews', fk_workspace_id: 'workspace'}]}, baseContext));
const retainedContext = {...baseContext,
  'Read Base Registry': {result: {baseId: 'retained-base'}}};
const existingBase = invoke('Resolve Domain Base', {list: [
  {id: 'retained-base', title: 'sample--interviews', fk_workspace_id: 'workspace'}]}, retainedContext);
assert.equal(existingBase.baseId, 'retained-base');
assert.throws(() => invoke('Resolve Domain Base', {list: [
  {id: 'foreign-base', title: 'sample--interviews', fk_workspace_id: 'workspace'}]}, retainedContext));
const observedClaim = invoke('Keep Source Claim', {result: {...claim, canExecute: false}},
  {'Keep Access Plan': context});
assert.equal(observedClaim.observeOnly, true);
const conflictingClaim = invoke('Keep Source Claim', {result: {
  ...claim, operation: 'rotate', accessKind: 'reader', canExecute: false}},
{'Keep Access Plan': context});
assert.equal(invoke('Respond Active Claim', conflictingClaim).activeOperation, 'rotate');
assert.deepEqual(graph.connections['Claim Executable'].main[1].map(edge => edge.node),
  ['Resume Bound Sync']);
assert.throws(() => invoke('Resolve Domain Base', {list: []},
  {...baseContext, 'Keep Source Claim': observedClaim}));
const observedBase = invoke('Resolve Domain Base', {list: [
  {id: 'retained-base', title: 'sample--interviews', fk_workspace_id: 'workspace'}]},
  {...retainedContext, 'Keep Source Claim': observedClaim});
assert.equal(observedBase.observeOnly, true);
const sourceContext = {...observedBase, accessKind: 'reader', alias: 'Read Model',
  schema: 'extra_read', state: 'awaiting_grants'};
assert.throws(() => invoke('Inspect Reader Sources', {list: []},
  {'Merge Reader State': sourceContext}), /claim_observation_cannot_create/);

const integrationContext = {domain: 'sample', pair: 'interviews', schema: 'extra_read',
  generatedValue: 'synthetic-only', baseId: 'retained-base'};
const integrationLookup = {'Prepare Reader Begin': integrationContext,
  'Begin Reader Source': {result: {role: `nocodb_${hash}_reader`, integrationId: null}}};
const integration = invoke('Prepare Reader Integration', {list: []}, integrationLookup);
assert.equal(integration.payload.title, 'automation-data/sample/interviews/reader');
assert.throws(() => invoke('Prepare Reader Integration', {list: [
  {id: 'foreign-integration', title: integration.payload.title}]}, integrationLookup));

for (const kind of ['Reader', 'Operator']) {
  const accessKind=kind.toLowerCase();
  const base={domain:'sample',pair:'interviews',operation:'rotate',requestedAccessKind:accessKind,
    baseId:'base-retained',schema:`extra_${accessKind}`};
  const selection={sourceId:'source-retained',selectedIntegrationId:'integration-retained'};
  const sourceMetadata={id:selection.sourceId,base_id:base.baseId,
    fk_integration_id:selection.selectedIntegrationId,alias:kind==='Reader'?'Read Model':'Operator',
    config:{searchPath:[base.schema]},is_data_readonly:kind==='Reader',is_schema_readonly:true};
  const validated=invoke(`Validate ${kind} Source`,sourceMetadata,{
    [kind==='Reader'?'Start Reader':'Prepare Operator']:base,
    [`Read ${kind} State`]:{result:{state:'rotating',operation:'rotate'}},
    [`Discover ${kind} Source`]:selection});
  assert.equal(validated.registryOperation,'rotate',`${kind} read-back must retain the registry operation`);
  assert.equal(validated.operation,'rotate');
  const partial = nodes.get(`${kind} Error Rotation`).parameters.conditions.conditions;
  const acceptsPartialState = state => partial.every(condition => {
    const values = {state, registryOperation: 'rotate', operation: 'rotate', requestedAccessKind: kind.toLowerCase()};
    const left = new Function('$json', `return ${condition.leftValue.slice(3, -2)};`)(values);
    if (condition.operator.type === 'boolean') return left === true;
    return left === condition.rightValue;
  });
  assert.equal(acceptsPartialState('rotating'), true, `${kind} partial retry must bypass old-credential probe`);
  assert.equal(acceptsPartialState('error'), true);
  assert.equal(acceptsPartialState('ready'), false);
  const node = nodes.get(`Rotate ${kind} Credential`);
  assert.equal(node.parameters.query,
    'SELECT platform_operations.rotate_nocodb_source_credential($1, $2, $3, $4, $5, $6) AS result;');
  assert.match(node.parameters.options.queryReplacement, /\.pair \|\| 'default'/);
  assert.match(node.parameters.options.queryReplacement, /\.operationId/);
}
for (const name of ['Begin Reader Source', 'Begin Operator Source',
  'Record Reader Integration', 'Record Operator Integration',
  'Record Reader Job', 'Record Operator Job',
  'Record Reader Ready', 'Record Operator Ready',
  'Rotate Reader Credential', 'Rotate Operator Credential', 'Record Source Error']) {
  const binding = nodes.get(name).parameters.options.queryReplacement;
  assert.match(binding, /\.pair \|\| 'default'/);
  assert.match(binding, /\.operationId/);
  assert.match(binding, /\.generation/);
}
const authorityFields = ['valid', 'loginValid', 'schemaPrivilegesValid',
  'objectPrivilegesValid', 'defaultPrivilegesValid', 'outsideSchemaDenied',
  'databaseIsolationValid', 'forbiddenAttributesDenied',
  'forbiddenMembershipsDenied', 'ddlDenied', 'controlledDmlPresent'];
const authority = Object.fromEntries(authorityFields.map(field => [field, true]));
const readerDecision = invoke('Require Reader PostgreSQL',
  {result: {...authority, accessKind: 'reader'}},
  {'Validate Reader Source': {domain: 'sample'}, 'Normalize Source Request': named});
const operatorDecision = invoke('Require Operator PostgreSQL',
  {result: {...authority, accessKind: 'operator'}},
  {'Validate Operator Source': {domain: 'sample'}, 'Normalize Source Request': named});
assert.equal(readerDecision.rotateTarget, true);
assert.equal(operatorDecision.rotateTarget, false);

const readySource = {accessKind: 'reader', state: 'ready', baseId: 'retained-base',
  sourceId: 'reader-source', integrationId: 'reader-integration',
  sourceCreateJobId: 'reader-job', sourceCreateJobState: 'completed',
  sourceDiscovered: true, sourceReadBack: true, generation: 3,
  credentialGeneration: 1, operationStartedAt: '2026-09-29T00:00:00Z',
  updatedAt: '2026-09-29T00:01:00Z', validatedAt: '2026-09-29T00:01:00Z',
  dataEditAllowed: false, schemaEditAllowed: false,
  postgresqlValidation: {...authority, controlledDmlPresent: false}};
const namedResponse = invoke('Prepare Source Response',
  {reader: readySource, operator: null},
  {'Normalize Source Request': {...named, operation: 'sync'}});
const legacyResponse = invoke('Prepare Source Response',
  {reader: readySource, operator: null},
  {'Normalize Source Request': legacy});
assert.equal(namedResponse.pair, 'interviews');
assert.equal(Object.hasOwn(legacyResponse, 'pair'), false);
assert.deepEqual(Object.keys(namedResponse).sort(),
  [...Object.keys(legacyResponse), 'pair'].sort());

assert.equal(graph.nodes.filter(node => node.type === 'n8n-nodes-base.wait').length, 0);
for (const kind of ['Reader', 'Operator']) {
  const code = nodes.get(`Initialize ${kind} Poll`).parameters.jsCode;
  assert.match(code, /generatedValue, payload, \.\.\.safeContext/);
  assert.equal(nodes.get(`Wait ${kind} Job`).type, 'n8n-nodes-base.code');
}

console.log('NocoDB named pair workflow boundaries passed.');

const statusRequest = invoke('Normalize Source Request', {body: {
  domain:'sample', pair:'interviews', operation:'status'}});
assert.equal(statusRequest.operation,'status');
assert.equal(nodes.get('Read Source Operation').parameters.query,
  'SELECT platform_operations.read_nocodb_operation_state($1, $2) AS result;');
const statusResult = invoke('Prepare Operation Status', {result: {
  operationId:previousOperation,phase:'uncertain',operation:'rotate',accessKind:'operator',generation:2}},
  {'Normalize Source Request':statusRequest});
assert.equal(statusResult.claim.operationId,previousOperation);
assert.equal(statusResult.claim.phase,'uncertain');
assert.deepEqual(invoke('Prepare Operation Status',{result:null},
  {'Normalize Source Request':statusRequest}).claim,null);
assert.throws(()=>invoke('Prepare Operation Status',{result:{password:'untrusted'}},
  {'Normalize Source Request':statusRequest}));
