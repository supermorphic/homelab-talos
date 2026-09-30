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
from pathlib import Path
sys.path.insert(0,'scripts/lib')
from automation_data_enrollment import prepare, make_job, state, save_state, N8nEnrollment, SOURCES
from automation_data_client import PrivateFileError, write_private_file_exclusive
root=Path(sys.argv[1]).resolve()
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
printf '%s\n' 'Discovery installation preconditions, retained candidates, and owned cleanup passed.'
if [[ "${1:-}" == --with-sql ]]; then
	bash scripts/test/automation-data-discovery-sql-test.sh
fi
