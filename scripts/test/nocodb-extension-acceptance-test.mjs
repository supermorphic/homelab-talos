import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const graph=JSON.parse(readFileSync('kubernetes/apps/automation/n8n/app/workflows/nocodb-acceptance-domain.json','utf8'));
assert.equal(new Set(graph.nodes.map(n=>n.id)).size,graph.nodes.length,
  'Every n8n node must have a distinct ID');
const nodes=new Map(graph.nodes.map(n=>[n.name,n]));
for(const operation of ['extensions','extensions-cleanup']) {
  const result=new Function('$json',nodes.get('Normalize Acceptance Request').parameters.jsCode)(
    {body:{operation,runId:'synthetic-run'}})[0].json;
  assert.equal(result.operation,operation);
}
const sql=nodes.get('Grant Extended Acceptance Access').parameters.query;
assert.match(sql,/SET LOCAL ROLE automation_data_acceptance_owner/);
assert.match(sql,/REVOKE ALL ON FUNCTION app\.withheld_admin\(\) FROM PUBLIC/);
assert.match(sql,/GRANT EXECUTE ON FUNCTION app\.record_integration_fact\(bigint,text\)/);
assert.doesNotMatch(sql,/GRANT .*withheld_bookkeeping|GRANT .*withheld_admin/);
assert.match(nodes.get('Cleanup Extended Acceptance').parameters.query,/fact = 'acceptance:' \|\| \$1/);
console.log('Fixed source-pair and application acceptance contract passed.');
