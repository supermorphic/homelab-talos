import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const root = mkdtempSync(join(tmpdir(), 'nocodb-restore-request-'));
const baseUrl = `http://${process.env.APP_SERVICE}.automation-data.svc.cluster.local:8080`;
const secretFile = join(root, 'signin.json');
const tokenFile = join(root, 'session.jwt');
const bounded = async (path, options = {}, allowed = [200], parseJson = true, maxBytes = 65536) => {
  const response = await fetch(`${baseUrl}${path}`, {...options, redirect:'error', signal: AbortSignal.timeout(60000)});
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > maxBytes) throw new Error('response_exceeded_bound');
  if (!allowed.includes(response.status)) throw new Error(`unexpected_http_${response.status}`);
  return {status: response.status, bytes, json: parseJson && bytes.byteLength ? JSON.parse(new TextDecoder().decode(bytes)) : null};
};
const list = (value) => Array.isArray(value) ? value : (value?.list || value?.data || []);
let insertedId = null;
let decisionTable = null;
let jwt = '';
try {
  const health = await bounded('/api/v1/health');
  if (health.json?.message !== 'OK') throw new Error('health_contract_failed');

  writeFileSync(secretFile, JSON.stringify({email: process.env.ADMIN_EMAIL, password: process.env.ADMIN_PASSWORD}), {mode: 0o600});
  const signin = await bounded('/api/v1/auth/user/signin', {method:'POST', headers:{'Content-Type':'application/json'}, body:readFileSync(secretFile)});
  if (typeof signin.json?.token !== 'string' || !/^[A-Za-z0-9._-]+$/.test(signin.json.token)) throw new Error('signin_contract_failed');
  writeFileSync(tokenFile, signin.json.token, {mode: 0o600});
  jwt = readFileSync(tokenFile, 'utf8');
  const headers = {'xc-auth':jwt};

  const registry = JSON.parse(process.env.SOURCE_REGISTRY);
  const retained = registry.items.filter((item) => item.domain === 'automation_data_acceptance');
  const pairs = [...new Set(retained.map((item) => item.pair || 'default'))].sort();
  if (!pairs.includes('default') || retained.length < 2 ||
      retained.some((item) => item.state !== 'ready' || item.valid !== true)) throw new Error('registry_base_mismatch');
  const bases = list((await bounded('/api/v2/meta/bases', {headers})).json);
  const workspaces = list((await bounded('/api/v2/meta/workspaces', {headers})).json);
  let base, reader, operator;
  for (const pair of pairs) {
    const entries = retained.filter((item) => (item.pair || 'default') === pair);
    const ids = [...new Set(entries.map((item) => item.baseId))];
    if (ids.length !== 1 || typeof ids[0] !== 'string' || !ids[0] ||
        entries.filter((item) => item.accessKind === 'reader').length !== 1 ||
        entries.filter((item) => item.accessKind === 'operator').length > 1 ||
        (pair === 'default' && entries.length !== 2)) throw new Error('registry_pair_mismatch');
    const title = pair === 'default' ? 'automation_data_acceptance' : `automation_data_acceptance--${pair}`;
    const baseMatches = bases.filter((item) => item?.id === ids[0] && item?.title === title);
    if (baseMatches.length !== 1) throw new Error('base_contract_failed');
    const pairBase = baseMatches[0];
    const workspaceId = pairBase.fk_workspace_id || pairBase.workspace_id;
    if (typeof workspaceId !== 'string' || !workspaceId ||
        workspaces.filter((item) => item?.id === workspaceId).length !== 1) throw new Error('workspace_contract_failed');
    const integrations = list((await bounded(`/api/v2/meta/workspaces/${workspaceId}/integrations`, {headers})).json);
    const summaries = list((await bounded(`/api/v2/meta/bases/${pairBase.id}/sources`, {headers})).json);
    const sourceObjects = [];
    for (const summary of summaries) sourceObjects.push((await bounded(`/api/v2/meta/bases/${pairBase.id}/sources/${summary.id}`, {headers})).json);
    const intrinsicSources = sourceObjects.filter((item) => item?.alias !== 'Read Model' && item?.alias !== 'Operator');
    if (intrinsicSources.length !== 1 || sourceObjects.length !== entries.length + 1) throw new Error('managed_source_count_failed');
    const intrinsic = intrinsicSources[0];
    const intrinsicConfigUnset = !Object.hasOwn(intrinsic, 'config') || intrinsic.config === null;
    if (typeof intrinsic.id !== 'string' || !/^[A-Za-z0-9_-]+$/.test(intrinsic.id) ||
        intrinsic.base_id !== pairBase.id || intrinsic.fk_workspace_id !== workspaceId || intrinsic.alias !== null ||
        intrinsic.type !== 'pg' || intrinsic.fk_integration_id !== null || intrinsic.fk_sql_executor_id !== null ||
        intrinsic.is_local !== true || intrinsic.is_meta !== false || intrinsic.enabled !== true || intrinsic.deleted !== false ||
        intrinsic.is_encrypted !== true || intrinsic.is_data_readonly !== false || intrinsic.is_schema_readonly !== false ||
        !intrinsicConfigUnset || intrinsic.meta !== null || intrinsic.description !== null || intrinsic.order !== 1 ||
        !Array.isArray(intrinsic.upgraderQueries)) throw new Error('intrinsic_source_contract_failed');
    for (const entry of entries) {
      const alias = entry.accessKind === 'reader' ? 'Read Model' : 'Operator';
      const matches = sourceObjects.filter((item) => item?.alias === alias);
      if (matches.length !== 1 || matches[0].id !== entry.sourceId ||
          matches[0].fk_integration_id !== entry.integrationId) throw new Error('registry_source_mismatch');
      const source = matches[0];
      const path = source?.config?.searchPath || source?.config?.search_path;
      const schema = entry.schema || (entry.accessKind === 'reader' ? 'read_model' : 'operator');
      if (JSON.stringify(path) !== JSON.stringify([schema]) || source.is_schema_readonly !== true ||
          source.is_data_readonly !== (entry.accessKind === 'reader')) throw new Error('source_schema_contract_failed');
      const integration = integrations.filter((item) => item.id === entry.integrationId);
      const expectedTitle = `automation-data/automation_data_acceptance/${pair === 'default' ? '' : pair + '/'}${entry.accessKind}`;
      if (integration.length !== 1 || integration[0].title !== expectedTitle ||
          integration[0].type !== 'database' || integration[0].sub_type !== 'pg') throw new Error('registry_integration_mismatch');
    }
    if (pair === 'default') {
      base = pairBase;
      reader = sourceObjects.find((item) => item.alias === 'Read Model');
      operator = sourceObjects.find((item) => item.alias === 'Operator');
    } else {
      const pairTables = list((await bounded(`/api/v2/meta/bases/${pairBase.id}/tables`, {headers})).json);
      if (!pairTables.length || pairTables.some((table) => !entries.some((entry) => entry.sourceId === table.source_id)))
        throw new Error('named_pair_tables_failed');
      for (const table of pairTables) {
        const views = list((await bounded(`/api/v2/meta/tables/${table.id}/views`, {headers})).json);
        if (!views.length) throw new Error('named_pair_view_failed');
        await bounded(`/api/v2/tables/${table.id}/records?limit=1`, {headers});
      }
    }
  }

  const tables = list((await bounded(`/api/v2/meta/bases/${base.id}/tables`, {headers})).json);
  const facts = tables.find((table) => table?.title === 'acceptance_facts' && table.table_name === 'acceptance_facts' && table.schema === null && table.source_id === reader.id);
  decisionTable = tables.find((table) => table?.title === 'acceptance_decision' && table.table_name === 'acceptance_decision' && table.schema === null && table.source_id === operator.id);
  if (tables.length !== 2 || !facts?.id || !decisionTable?.id) throw new Error('schema_separation_failed');
  await bounded(`/api/v2/tables/${facts.id}/records?limit=100`, {headers});
  await bounded(`/api/v2/tables/${decisionTable.id}/records?limit=100`, {headers});

  const id = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]+$/.test(value);
  const factResponse = (await bounded(`/api/v2/tables/${facts.id}/records?where=(id,eq,-334)&limit=2`, {headers})).json;
  const factRows = list(factResponse);
  if (factRows.length !== 1 || (factResponse.pageInfo && factResponse.pageInfo.totalRows !== 1)) throw new Error('recovery_fact_missing');
  const fact = factRows[0];
  if (Object.keys(fact).some((key) => key.toLowerCase().startsWith('attach')) ||
      Number(fact.id) !== -334 || fact.run_id !== 'recovery-canary-v2' || fact.fact !== 'artifact-available' ||
      fact.artifact_id !== 'issue334-artifact-v1' || fact.artifact_uri !== 'https://artifacts.example.invalid/issue334/artifact-v1' ||
      fact.artifact_media_type !== 'text/plain' || Number(fact.artifact_size_bytes) !== 37 ||
      fact.artifact_sha256 !== '09dbca24661414e7c9bfdb82b6ee39484466ae4bc4c9775501e2789fe39786a3') {
    throw new Error('recovery_fact_invalid');
  }
  const decisionResponse = (await bounded(`/api/v2/tables/${decisionTable.id}/records?where=(run_id,eq,recovery-canary-v2)&limit=2`, {headers})).json;
  const decisionRows = list(decisionResponse);
  if (decisionRows.length !== 1 || (decisionResponse.pageInfo && decisionResponse.pageInfo.totalRows !== 1)) throw new Error('recovery_decision_missing');
  const decision = decisionRows[0];
  if (!Number.isSafeInteger(Number(decision.id)) || decision.run_id !== 'recovery-canary-v2' || decision.decision !== 'retain' ||
      Object.keys(decision).some((key) => key.toLowerCase().startsWith('attach'))) throw new Error('recovery_decision_invalid');
  const views = list((await bounded(`/api/v2/meta/tables/${facts.id}/views`, {headers})).json);
  if (views.length !== 1 || !id(views[0].id) || views[0].fk_model_id !== facts.id ||
      views[0].title !== 'acceptance_facts' || views[0].type !== 3 || views[0].uuid !== null) throw new Error('saved_view_failed');

  const readerDenied = await bounded(`/api/v2/tables/${facts.id}/records`, {
    method:'POST', headers:{...headers,'Content-Type':'application/json'},
    body:JSON.stringify({id:2147483647,fact:`restore-denial-${process.env.RUN_HASH}`})
  }, [403]);
  if (readerDenied.status !== 403) throw new Error('reader_denial_failed');

  const inserted = await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
    method:'POST', headers:{...headers,'Content-Type':'application/json'},
    body:JSON.stringify({run_id:`restore-${process.env.RUN_HASH}`,decision:'restore-probe'})
  });
  insertedId = inserted.json?.id;
  if (typeof insertedId !== 'number' && typeof insertedId !== 'string') throw new Error('operator_authentication_failed');
  const protectedDenied = await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
    method:'PATCH', headers:{...headers,'Content-Type':'application/json'},
    body:JSON.stringify([{id:insertedId,protected_created_at:'2000-01-01T00:00:00Z'}])
  }, [400]);
  if (protectedDenied.status !== 400) throw new Error('operator_denial_failed');

  await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
    method:'DELETE', headers:{...headers,'Content-Type':'application/json'}, body:JSON.stringify([{id:insertedId}])
  });
  insertedId = null;
  console.log('nocodb_restore_assertions=passed');
} finally {
  if (insertedId !== null && decisionTable?.id && jwt) {
    try {
      await bounded(`/api/v2/tables/${decisionTable.id}/records`, {
        method:'DELETE', headers:{'xc-auth':jwt,'Content-Type':'application/json'}, body:JSON.stringify([{id:insertedId}])
      });
    } catch {}
  }
  rmSync(root, {recursive:true,force:true});
}
