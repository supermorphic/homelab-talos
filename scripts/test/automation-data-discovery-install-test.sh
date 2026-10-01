#!/usr/bin/env bash
# Installation guards and manifests only; never contacts a live service.
set -euo pipefail
source scripts/lib/automation-data-discovery-install.sh
scratch="$(mktemp -d)"
trap 'rm -r -- "$scratch"' EXIT
chmod 700 "$scratch"
printf '%s\n' '{"metadata":{"labels":{"homelab-talos/run-id":"fixture-run"}},"status":{"conditions":[{"type":"Complete","status":"True"}]}}' >"$scratch/state.json"
discovery_backup_ready "$scratch/state.json" fixture-run
if discovery_backup_ready "$scratch/state.json" wrong-run; then
	echo 'Wrong backup ownership accepted.' >&2
	exit 1
fi
printf '%s\n' '{"metadata":{"labels":{"homelab-talos/run-id":"foreign-run"}}}' >"$scratch/state.json"
if discovery_resource_owned "$scratch/state.json" fixture-run; then
	echo 'Foreign cleanup accepted.' >&2
	exit 1
fi
printf '%s\n' '{"status":{"conditions":[{"type":"Failed","status":"True"}]}}' >"$scratch/state.json"
if discovery_backup_ready "$scratch/state.json" fixture-run; then
	echo 'Failed backup accepted.' >&2
	exit 1
fi
# Actual guard dependencies are mocked; each failure must stop before the mutation call.
require_deployed_source() { return 1; }
if discovery_require_source; then
	echo 'Undeployed source accepted.' >&2
	exit 1
fi
verify_test_lease_holder() { return 1; }
if discovery_require_lease /unused fixture-run "$scratch"; then
	echo 'Lost Lease accepted.' >&2
	exit 1
fi
uv run --locked python - "$scratch" <<'PY'
import contextlib,io,json,sys
import os
from pathlib import Path
sys.path.insert(0,'scripts/lib')
from automation_data_enrollment import prepare, make_job, state, save_state, N8nEnrollment, SOURCES
from automation_data_client import PrivateFileError, write_private_file_exclusive
root=Path(sys.argv[1]).resolve()
import automation_data_enrollment as enrollment
assert hasattr(enrollment, 'initialize_access'), 'Installer must create protected access/profile directories'
os.environ['XDG_CONFIG_HOME']=str(root/'config')
access=root/'config/homelab/automation-data'
enrollment.initialize_access(access)
config=json.loads((access/'access.json').read_text())
for key in ('applicationProfileRoot','migratorProfileRoot'):
    assert Path(config[key]).is_dir()
    assert Path(config[key]).stat().st_mode & 0o777 == 0o700
assert (access/'access.json').stat().st_mode & 0o777 == 0o600
before=(access/'access.json').read_bytes()
enrollment.initialize_access(access)
assert (access/'access.json').read_bytes()==before, 'Existing enrollment overwritten'
for unsafe in ('symlink','checkout'):
    selected=root/unsafe
    if unsafe=='symlink': selected.symlink_to(root/'config', target_is_directory=True)
    else:
        selected.mkdir(mode=0o700)
        (selected/'.git').write_text('synthetic worktree marker')
    os.environ['XDG_CONFIG_HOME']=str(selected/'new-config')
    try: enrollment.initialize_access(selected/'new-config/homelab/automation-data')
    except PrivateFileError: pass
    else: raise AssertionError('Unsafe bootstrap location accepted')
    assert not (selected/'new-config').exists(), 'Bootstrap created files through an unsafe ancestor'
os.environ['XDG_CONFIG_HOME']=str(root/'config')
assert not (access/'n8n-api-key').exists()
try:
    manifest=enrollment.make_native_job('fixture-job','fixture-run','fixture-config','fixture-candidates','preflight')
except TypeError as exc:
    raise AssertionError('Native enrollment needs a read-only preflight before reader mutation') from exc
pod=manifest['spec']['template']['spec']
assert pod['automountServiceAccountToken'] is False
assert pod['containers'][0]['args'][-1]=='preflight'
assert pod['securityContext']['runAsUser']==1000
assert {v['valueFrom']['secretKeyRef']['key'] for v in pod['containers'][0]['env'] if 'valueFrom' in v}=={'n8n-password','N8N_ENCRYPTION_KEY'}
assert hasattr(enrollment, 'native_input'), 'Native enrollment must work without an API-key file'
enrollment.prepare(access)
enrollment.native_input(access, 'fixture-project', root/'native-input.json')
bundle=json.loads((root/'native-input.json').read_text())
assert bundle['projectId']=='fixture-project' and bundle['verifyOnly'] is False
assert len(bundle['credentials'])==4
assert {c['name'] for c in bundle['credentials']}=={entry[4] for entry in SOURCES.values()}
assert bundle['workflow']['active'] is False
assert all(node.get('webhookId') for node in bundle['workflow']['nodes'] if node['type']=='n8n-nodes-base.webhook'), 'CLI import requires explicit webhook IDs'
assert not (access/'n8n-api-key').exists()
enrollment.native_start(access)
try: enrollment.native_input(access, 'fixture-project', root/'retry.json')
except PrivateFileError: pass
else: raise AssertionError('Ambiguous native import retried')
enrollment.native_complete(access)
enrollment.native_input(access, 'fixture-project', root/'native-verify.json')
verified=json.loads((root/'native-verify.json').read_text())
assert verified['verifyOnly'] is True
assert verified['credentials']==bundle['credentials']
try: enrollment.native_input(access, 'other-project', root/'wrong-project.json')
except PrivateFileError: pass
else: raise AssertionError('Retained credentials moved between projects')
with contextlib.redirect_stdout(io.StringIO()) as captured:
    first=prepare(root);second=prepare(root)
assert first['operationId']==second['operationId']
assert captured.getvalue()==''
for source in ('platform','nocodb','n8n'):
    job=make_job(source,'fixture-job','fixture-run','fixture-config','fixture-candidates')
    assert job['spec']['backoffLimit']==0
    assert job['spec']['activeDeadlineSeconds']==120
    pod=job['spec']['template']['spec']
    assert pod['automountServiceAccountToken'] is False
    assert pod['containers'][0]['image']=='postgres:17.11-alpine3.24'
    assert pod['containers'][0]['env'][0]['valueFrom']['secretKeyRef']['key']=='postgres-superuser-password'
    assert not any('password' in a.lower() for a in pod['containers'][0].get('args',[]))
    assert 'SYNTHETIC' not in json.dumps(job)
original=state(root)
write_private_file_exclusive(root/'n8n-api-key',b'SYNTHETIC_N8N_ADMIN_SENTINEL')
class Client(N8nEnrollment):
    def __init__(self):
        super().__init__(root,lambda:None)
        self.items=[];self.created=0;self.fail=False
    def request(self,method,path,body=None):
        if method=='GET':return {'data':self.items,'nextCursor':None}
        self.created+=1
        if self.fail:raise PrivateFileError('synthetic_transport_failure')
        item={'id':'fixture-created','name':body['name'],'type':body['type']}
        self.items.append(item)
        return item
client=Client()
client.items=[{'id':'foreign','name':SOURCES['header'][4],'type':'httpHeaderAuth'}]
try:client.enroll('header')
except PrivateFileError:pass
else:raise AssertionError('Unrelated credential name adopted')
assert client.created==0
client.items=[];client.enroll('header');client.enroll('header')
assert client.created==1, 'Retry duplicated credential creation'
assert state(root)['credentials']['header']=='fixture-created'
client.fail=True
try:client.enroll('platform')
except PrivateFileError:pass
else:raise AssertionError('Failed request accepted')
assert state(root)['creating']=='platform'
try:client.enroll('platform')
except PrivateFileError:pass
else:raise AssertionError('Ambiguous creation repeated')
assert client.created==2
save_state(root,original)
workflow_state=state(root)
workflow_state['credentials']={source:'fixture-'+source for source in SOURCES}
save_state(root,workflow_state)
class WorkflowClient(N8nEnrollment):
    def __init__(self):
        super().__init__(root,lambda:None)
        self.body=None
        self.published=False
    def request(self,method,path,body=None):
        if path=='workflows?limit=100':return {'data':[],'nextCursor':None}
        if path=='workflows':
            self.body=body
            return {'id':'fixture-inventory'}
        if method=='GET':return {**self.body,'active':False}
        assert path=='workflows/fixture-inventory/publish', 'Pinned n8n publication endpoint changed'
        self.published=True
        return {'active':True}
workflow_client=WorkflowClient()
workflow_client.workflow()
assert workflow_client.published
save_state(root,original)
original['credentials']['unrelated']='unknown';save_state(root,original)
try:prepare(root)
except PrivateFileError:pass
else:raise AssertionError('Ambiguous prior installation accepted')
PY
node - "$scratch/native-input.json" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const filename = './scripts/lib/automation-data-discovery-enroll.cjs';
assert(fs.existsSync(filename), 'Pinned CLI enrollment must reject overwrite before import');
const { checkExisting } = require(process.cwd() + '/' + filename);
const bundle = JSON.parse(fs.readFileSync(process.argv[2]));
checkExisting(bundle, [], []);
const rows = bundle.credentials.map(({ id, name, type }) => ({ id, name, type, projectId: bundle.projectId }));
const workflows = [{ id: bundle.workflow.id, name: bundle.workflow.name, projectId: bundle.projectId }];
assert.throws(() => checkExisting(bundle, rows, workflows), 'Import must never upsert an existing ID');
const retry = { ...bundle, verifyOnly: true };
checkExisting(retry, rows, workflows);
assert.throws(() => checkExisting(retry, rows.slice(1), workflows), 'Missing retained credential must stop');
assert.throws(() => checkExisting(retry, [...rows, { ...rows[0], id: 'foreign' }], workflows));
assert.throws(() => checkExisting(retry, rows.map(r => ({ ...r, projectId: 'foreign' })), workflows));
assert.throws(() => checkExisting(retry, rows, [{ ...workflows[0], id: 'foreign' }]));
JS
printf '%s\n' 'Discovery installation preconditions, retained candidates, and owned cleanup passed.'
if [[ "${1:-}" == --with-sql ]]; then
	bash scripts/test/automation-data-discovery-sql-test.sh
fi
