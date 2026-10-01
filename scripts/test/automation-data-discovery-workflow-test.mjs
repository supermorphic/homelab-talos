import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const path='kubernetes/apps/automation/n8n/app/workflows/automation-data-credential-inventory.json';
assert.ok(fs.existsSync(path),'Private inventory workflow implementation missing');
const workflow=JSON.parse(fs.readFileSync(path));
const nodes=Object.fromEntries(workflow.nodes.map(n=>[n.name,n]));
const evaluate=(name,input,values={},now=Date.now())=>vm.runInNewContext(`(function(){${nodes[name].parameters.jsCode}\n})()`, {
  $input:{first:()=>({json:input})}, $:name=>({first:()=>({json:values[name]})}),
  Date:class extends Date {static now(){return now;}}, Buffer,
});
assert.equal(nodes.Webhook.parameters.authentication,'headerAuth');
assert.equal(nodes.Webhook.parameters.path,'automation-data-credential-inventory');
for(const setting of ['saveManualExecutions','saveExecutionProgress']) assert.equal(workflow.settings[setting],false);
for(const setting of ['saveDataErrorExecution','saveDataSuccessExecution']) assert.equal(workflow.settings[setting],'none');
assert.equal(workflow.settings.executionTimeout,30);
const credentials=new Set(workflow.nodes.flatMap(n=>Object.values(n.credentials??{}).map(c=>c.name)));
assert.deepEqual([...credentials].sort(),['Automation Data Inventory Header','Automation Data Inventory Reader','NocoDB Inventory Reader','n8n Inventory Reader'].sort());
const init=evaluate('Validate Request',{body:{action:'list'}})[0].json;
assert.equal(init.valid,true);
for (const body of [{},{action:'delete'},{action:'list',url:'https://example.com'}, {action:'resolve',domain:'sample',purpose:'application'}, {action:'resolve',domain:'../x',purpose:'migration'}]) {
  assert.equal(evaluate('Validate Request',{body})[0].json.valid,false);
}
assert.equal(evaluate('Validate Request',{body:{action:'resolve',domain:'sample',purpose:'source',pair:'extra',accessKind:'reader'}})[0].json.valid,true);
const revisions={platform:'automation-data-discovery-v1',nocodb:'nocodb-2026.08.2-v1',n8n:'n8n-2.36.7-v1'};
const snapshot=(source,objects=[])=>({source,status:'ok',complete:true,schemaRevision:revisions[source],observedAt:new Date().toISOString(),objectCount:objects.length,fingerprint:'a'.repeat(32),objects});
const values={'Validate Request':init};
for (const source of Object.keys(revisions)) for(const pass of [1,2]) values[`Observe ${source} 1.${pass}`]={snapshot:snapshot(source)};
const collect=()=>evaluate('Collect Attempt 1',{},values)[0].json;
assert.equal(collect().retryRequired,false);
assert.ok(collect().sources.every(s=>s.complete));
values['Observe n8n 1.2'].snapshot.observedAt=new Date(Date.now()-10).toISOString();
assert.ok(collect().sources.every(s=>s.complete),'collection timestamps must not change fingerprint stability');
values['Observe n8n 1.2'].snapshot=snapshot('n8n',[{kind:'credential',id:'new-id',name:null,type:'postgres',updatedAt:new Date().toISOString()}]);
assert.equal(collect().retryRequired,true,'changed object count triggers whole-attempt retry');
for(const source of Object.keys(revisions)) for(const pass of [1,2]) values[`Observe ${source} 2.${pass}`]=values[`Observe ${source} 1.${pass}`];
const unstable=evaluate('Collect Attempt 2',{},values)[0].json;
assert.equal(unstable.retryRequired,false);
assert.equal(unstable.sources.find(s=>s.source==='n8n').errorCode,'unstable');
values['Observe n8n 1.2']={error:{message:'SENTINEL_SECRET_ERROR'}};
const partial=collect();
assert.equal(partial.sources.find(s=>s.source==='n8n').complete,false);
assert.ok(!JSON.stringify(partial).includes('SENTINEL_SECRET_ERROR'));
values['Observe n8n 1.2']={snapshot:{source:'n8n',status:'unavailable',complete:false,errorCode:'unsupported_schema'}};
assert.equal(collect().sources.find(s=>s.source==='n8n').errorCode,'unsupported_schema');
const observed=values['Observe platform 1.1'].snapshot;
observed.objectCount=1001;
assert.equal(collect().sources.find(s=>s.source==='platform').errorCode,'limit_exceeded');
observed.objectCount=0;
observed.objects=[{kind:'role',id:'fixture',password:'SENTINEL_SECRET_PAYLOAD'}];observed.objectCount=1;
assert.equal(collect().sources.find(s=>s.source==='platform').complete,false);
assert.ok(!JSON.stringify(collect()).includes('SENTINEL_SECRET_PAYLOAD'));
values['Observe platform 1.1']={snapshot:snapshot('platform',Array.from({length:1000},(_,i)=>({kind:'role',id:`fixture-${i}`})))};
values['Observe platform 1.2']=JSON.parse(JSON.stringify(values['Observe platform 1.1']));
assert.equal(collect().sources.find(s=>s.source==='platform').objectCount,1000);
const boundary=snapshot('platform');boundary.padding='';
boundary.padding='x'.repeat(1048576-Buffer.byteLength(JSON.stringify(boundary)));
values['Observe platform 1.1']={snapshot:boundary};
assert.equal(collect().sources.find(s=>s.source==='platform').errorCode,'invalid_response');
boundary.padding+='é';
assert.equal(collect().sources.find(s=>s.source==='platform').errorCode,'limit_exceeded');
values['Observe platform 1.1']={snapshot:snapshot('platform')};
const late=evaluate('Collect Attempt 1',{},values,init.startedAt+30001)[0].json;
assert.ok(late.sources.every(s=>!s.complete));
for(const node of workflow.nodes.filter(n=>n.type==='n8n-nodes-base.postgres')) {
  assert.equal(node.parameters.options.queryBatching,'transaction');
  assert.ok(node.parameters.query.includes('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY'));
  assert.ok(!node.parameters.query.includes('COMMIT'));
  assert.ok(node.parameters.query.includes('statement_timeout'));
  assert.ok(node.parameters.query.includes('platform_discovery.read_snapshot()'));
  assert.ok(!node.parameters.query.includes('$json'));
}
console.log('Private inventory authentication, stability, sanitization, and bounds passed.');
