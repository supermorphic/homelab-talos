const endpoint = `http://${process.env.APP_NAME}.automation.svc.cluster.local:5678/webhook/automation-data-canary`;
const response = await fetch(endpoint, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-Platform-Canary': process.env.CANARY_TOKEN}, body: '{}', signal: AbortSignal.timeout(60000)});
if (!response.ok) throw new Error(`Recovery canary returned HTTP ${response.status}`);
const body = await response.json();
const keys = Object.keys(body).sort();
if (JSON.stringify(keys) !== JSON.stringify(['database','executionId','role','status'])) throw new Error('Unexpected recovery response keys');
if (body.status !== 'ok' || body.database !== 'automation_data_canary' || body.role !== 'automation_data_canary_runtime' || typeof body.executionId !== 'string' || body.executionId.length === 0) throw new Error('Restored runtime identity mismatch');
console.log('restored_runtime_credential=authenticated');
