#!/usr/bin/env bash
# Server admission only; persistent fixture, network, RWX and recovery proofs are separate.
set -euo pipefail
[[ "$#" -eq 1 ]] || { echo 'Usage: application-boundary.sh <selected-test-kubeconfig>' >&2; exit 2; }
[[ "${APPLICATION_BOUNDARY_TEST_CONFIRM:-}" == 'test:application-boundary:server-admission' ]] || {
  echo 'Set APPLICATION_BOUNDARY_TEST_CONFIRM=test:application-boundary:server-admission for the fixed server-side dry-run scope.' >&2
  exit 2
}
uv run --locked python - "$1" <<'PY'
import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml
from scripts.openbao.guards import _controlled_body

config=sys.argv[1]
if not Path(config).is_file():
    sys.exit('Application admission test needs its selected invocation kubeconfig.')
kc=['kubectl','--kubeconfig',config]

def observe(*args):
    result=subprocess.run(kc+list(args),capture_output=True,text=True,check=False)
    if result.returncode:
        sys.exit('Application admission preconditions failed; no broader credential fallback is permitted.')
    return json.loads(result.stdout)

identity=observe('auth','whoami','-o','json')['status']['userInfo']['username']
if identity != 'system:serviceaccount:kube-system:homelab-test-runner':
    sys.exit('Application admission test requires the selected test-runner identity.')

rendered=subprocess.check_output(['kustomize','build','kubernetes/apps/applications/career-ops/platform'],text=True)
controls=[d for d in yaml.safe_load_all(rendered) if d['metadata']['name'] == 'career-ops-boundary-test']
if len(controls) != 4:
    sys.exit('Application admission source does not contain its four scope controls.')

def precondition():
    for expected in controls:
        args=['get',expected['kind'],expected['metadata']['name'],'-o','json']
        if ns:=expected['metadata'].get('namespace'):
            args+=['-n',ns]
        actual=observe(*args)
        if _controlled_body(expected) != _controlled_body(actual):
            sys.exit('Application admission scope controls differ from source; no request submitted.')
        if expected['kind']=='ValidatingAdmissionPolicy':
            status=actual.get('status',{})
            if status.get('observedGeneration') != actual['metadata']['generation'] or status.get('typeChecking',{}).get('expressionWarnings'):
                sys.exit('Application admission scope policy is not type-checked for its current generation.')

fixture=yaml.safe_load(Path('tests/fixtures/application-boundary/job.yaml').read_text())
cases=[('permitted offline template', fixture, True)]
for name,field,value in [
    ('host networking','hostNetwork',True),
    ('reconciliation identity','serviceAccountName','career-ops-reconciler'),
    ('worker token','automountServiceAccountToken',True),
    ('source credential','volumes',[{'name':'source','secret':{'secretName':'career-ops-source'}}]),
    ('artifact access','volumes',[{'name':'artifacts','persistentVolumeClaim':{'claimName':'cv-artifacts'}}]),
]:
    bad=copy.deepcopy(fixture);bad['spec']['template']['spec'][field]=value
    cases.append((name,bad,False))
bad=copy.deepcopy(fixture);bad['spec']['template']['spec']['containers'][0]['resources']['limits']['cpu']='2'
cases.append(('worker resource ceiling',bad,False))

with tempfile.TemporaryDirectory(prefix='application-admission-') as directory:
    for name,job,allowed in cases:
        path=Path(directory)/'job.yaml';path.write_text(yaml.safe_dump(job))
        # Repeat installed authority checks immediately before every API request.
        precondition()
        result=subprocess.run(kc+['create','--dry-run=server','-f',str(path),'-o','name'],capture_output=True,text=True,check=False)
        if allowed:
            if result.returncode or result.stdout.strip() != 'job.batch/career-ops-boundary-admission':
                sys.exit('Permitted server admission failed; no scheduling or image-pull failure counts as a denial.')
        elif result.returncode == 0 or 'career-ops-workloads' not in result.stderr or 'Forbidden' not in result.stderr:
            sys.exit('Negative admission did not identify the intended application workload control: '+name)
        print('Server admission case passed: '+name)
print('Server-side Job admission passed. No resources persisted; controller Pods, networking, RWX, pruning, source reconciliation, delivery and restore remain separate native acceptance.')
PY
