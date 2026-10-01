// Runs inside the pinned n8n image. The wrapper queries credential metadata only.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const { createRequire } = require('node:module');

function checkExisting(bundle, credentials, workflows) {
  if (!bundle.verifyOnly) {
    // The official import command upserts by ID. We permit creation only.
    assert.equal(credentials.length, 0);
    assert.equal(workflows.length, 0);
    return;
  }
  assert.equal(credentials.length, bundle.credentials.length);
  for (const expected of bundle.credentials) {
    const matches = credentials.filter(c => c.id === expected.id && c.name === expected.name
      && c.type === expected.type && c.projectId === bundle.projectId);
    assert.equal(matches.length, 1);
  }
  assert.equal(workflows.length, 1);
  assert.deepEqual(workflows[0], {
    id: bundle.workflow.id, name: bundle.workflow.name, projectId: bundle.projectId,
  });
}

async function main(input, mode = 'import') {
  assert(['import', 'preflight'].includes(mode));
  assert(process.env.N8N_ENCRYPTION_KEY);
  const bundle = JSON.parse(fs.readFileSync(input, 'utf8'));
  const n8nRequire = createRequire('/usr/local/lib/node_modules/n8n/package.json');
  const { Client } = n8nRequire('pg');
  const db = new Client({
    host: process.env.DB_POSTGRESDB_HOST, port: Number(process.env.DB_POSTGRESDB_PORT),
    database: process.env.DB_POSTGRESDB_DATABASE, user: process.env.DB_POSTGRESDB_USER,
    password: process.env.DB_POSTGRESDB_PASSWORD, connectionTimeoutMillis: 5000,
    statement_timeout: 5000,
  });
  await db.connect();
  let directory;
  try {
    if (mode === 'preflight') await db.query('BEGIN READ ONLY');
    assert.equal(n8nRequire('./package.json').version, '2.36.7');
    assert.equal((await db.query('SELECT id FROM project WHERE id=$1', [bundle.projectId])).rowCount, 1);
    const observe = async () => {
      const credentials = (await db.query(`
        SELECT c.id,c.name,c.type,s."projectId" FROM credentials_entity c
        LEFT JOIN shared_credentials s ON s."credentialsId"=c.id AND s.role='credential:owner'
        WHERE c.id=ANY($1::varchar[]) OR c.name=ANY($2::varchar[]) LIMIT 10`,
      [bundle.credentials.map(c => c.id), bundle.credentials.map(c => c.name)])).rows;
      const workflows = (await db.query(`
        SELECT w.id,w.name,s."projectId" FROM workflow_entity w
        LEFT JOIN shared_workflow s ON s."workflowId"=w.id AND s.role='workflow:owner'
        WHERE w.id=$1 OR w.name=$2 LIMIT 10`, [bundle.workflow.id, bundle.workflow.name])).rows;
      checkExisting(bundle, credentials, workflows);
    };
    await observe();
    if (mode === 'preflight') {
      process.stdout.write('discovery_native_preflight=verified\n');
      return;
    }
    if (!bundle.verifyOnly) {
      directory = fs.mkdtempSync('/tmp/discovery-import-');
      const importFile = (kind, value) => {
        const path = `${directory}/${kind}.json`;
        fs.writeFileSync(path, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
        // n8n may log exceptions containing input. No CLI output reaches pod logs.
        execFileSync('n8n', [`import:${kind}`, `--input=${path}`, `--projectId=${bundle.projectId}`],
          { stdio: 'ignore', timeout: 120000 });
      };
      importFile('credentials', bundle.credentials);
      importFile('workflow', [bundle.workflow]);
      bundle.verifyOnly = true;
      await observe(); // CLI error handling alone is not a success oracle.
    }
    const row = (await db.query('SELECT nodes,connections,settings FROM workflow_entity WHERE id=$1',
      [bundle.workflow.id])).rows[0];
    assert.deepEqual(row.nodes, bundle.workflow.nodes);
    assert.deepEqual(row.connections, bundle.workflow.connections);
    for (const [key, value] of Object.entries(bundle.workflow.settings)) {
      assert.deepEqual(row.settings[key], value);
    }
    process.stdout.write('discovery_native_enrollment=verified\n');
  } finally {
    if (directory) fs.rmSync(directory, { recursive: true });
    await db.end();
  }
}

module.exports = { checkExisting };
if (require.main === module) {
  main(process.argv[2], process.argv[3]).catch(() => {
    process.stderr.write('Discovery native enrollment stopped; retain the protected receipt.\n');
    process.exitCode = 1;
  });
}
