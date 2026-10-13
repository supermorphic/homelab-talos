#!/usr/bin/env bash
# Observe installed controls and enrollment state without reading credentials/data.
set -euo pipefail
[[ "$#" -eq 1 ]] || { echo 'Usage: application-boundary.sh <task-scoped-kubeconfig>' >&2; exit 2; }
uv run --locked python - "$1" <<'PY'
import copy
import json
import subprocess
import sys
from pathlib import Path

import yaml
from scripts.openbao.guards import _controlled_body

config = sys.argv[1]
if not Path(config).is_file():
    sys.exit('Application boundary verification needs its task-scoped kubeconfig.')
kc = ['kubectl', '--kubeconfig', config]

def read(*args):
    result = subprocess.run(kc + list(args), capture_output=True, text=True, check=False)
    if result.returncode:
        sys.exit('Application boundary observation failed; check deployed prerequisites and scoped read authority.')
    return json.loads(result.stdout) if result.stdout.strip() else None

identity = read('auth', 'whoami', '-o', 'json')['status']['userInfo']['username']
if identity != 'system:serviceaccount:kube-system:homelab-observer':
    sys.exit('Application boundary verification requires the scoped observer identity.')

controller=read('get','deployment','kustomize-controller','-n','flux-system','-o','json')
manager=next((c for c in controller['spec']['template']['spec']['containers'] if c['name']=='manager'),None)
flags=[] if manager is None else [a for a in manager.get('args',[]) if a.startswith('--no-remote-bases')]
if flags != ['--no-remote-bases=true']:
    sys.exit('The deployed kustomize controller does not deny remote bases.')

def get(item, optional=False):
    args=['get', item['kind'], item['metadata']['name'], '-o', 'json']
    if ns := item['metadata'].get('namespace'):
        args += ['-n', ns]
    if optional:
        args += ['--ignore-not-found']
    return read(*args)

def ready(item):
    g=item['metadata']['generation']
    return item.get('status',{}).get('observedGeneration') == g and any(
        c.get('type') == 'Ready' and c.get('status') == 'True' and c.get('observedGeneration') == g
        for c in item.get('status',{}).get('conditions',[]))

def controlled(item):
    item=copy.deepcopy(item)
    if item['kind'] == 'PersistentVolumeClaim':
        item['spec'].pop('volumeName',None)
    if item['kind'] == 'LimitRange':
        # The API derives Container defaults from max when not explicitly set.
        # Preserve explicit values so drift in defaults still fails observation.
        for limit in item['spec']['limits']:
            if limit['type'] == 'Container':
                defaults=limit.setdefault('default',{})
                requests=limit.setdefault('defaultRequest',{})
                for resource,value in limit.get('max',{}).items():
                    defaults.setdefault(resource,value)
                for resource,value in defaults.items():
                    requests.setdefault(resource,value)
    return _controlled_body(item)

rendered=subprocess.check_output(['kustomize','build','kubernetes/apps/applications/career-ops/platform'],text=True)
for expected in yaml.safe_load_all(rendered):
    actual=get(expected)
    if controlled(expected) != controlled(actual):
        sys.exit('An installed application control differs from the reviewed source: '+expected['kind']+'/'+expected['metadata']['name'])
    if expected['kind'] == 'Namespace' and any(actual['metadata'].get('labels',{}).get(k) != v for k,v in expected['metadata']['labels'].items()):
        sys.exit('Application namespace restriction labels differ from source.')
    if expected['kind'] == 'PersistentVolumeClaim':
        if actual.get('status',{}).get('phase') != 'Bound' or actual['metadata'].get('annotations',{}).get('kustomize.toolkit.fluxcd.io/prune') != 'disabled':
            sys.exit('A fixture volume is not Bound and prune protected.')
        pv=read('get','persistentvolume',actual['spec']['volumeName'],'-o','json')
        if (pv['spec'].get('persistentVolumeReclaimPolicy') != 'Retain' or pv['spec'].get('storageClassName') != 'career-ops-retain'
            or pv['spec'].get('claimRef',{}).get('uid') != actual['metadata']['uid'] or pv['spec'].get('csi',{}).get('driver') != 'driver.longhorn.io'):
            sys.exit('A fixture volume lacks its owned Longhorn Retain binding.')
    if expected['kind'] == 'ValidatingAdmissionPolicy':
        status=actual.get('status',{})
        if status.get('observedGeneration') != actual['metadata']['generation'] or status.get('typeChecking',{}).get('expressionWarnings'):
            sys.exit('Application admission policy type checking is incomplete or has warnings.')

units=list(yaml.safe_load_all(Path('kubernetes/apps/applications/career-ops/ks.yaml').read_text()))
for expected in units:
    actual=get(expected)
    if actual['spec'].get('suspend',False) != expected['spec']['suspend']:
        sys.exit('Application source consumption differs from reviewed suspension intent.')
    if expected['metadata']['name'] == 'career-ops-platform' and not ready(actual):
        sys.exit('Application platform has not reported Ready for its current generation.')

connection=list(yaml.safe_load_all(subprocess.check_output(['kustomize','build','kubernetes/apps/applications/career-ops/connection'],text=True)))
for expected in connection:
    actual=get(expected, optional=True)
    if actual is None:
        if not units[1]['spec']['suspend']:
            sys.exit('An active application connection is missing an enrolled source object.')
        continue
    if actual['spec'].get('suspend',False) != expected['spec']['suspend']:
        sys.exit('Application source/application suspension differs from reviewed intent.')
    for field in ('url','ref','secretRef','path','serviceAccountName','sourceRef','targetNamespace'):
        if field in expected['spec'] and actual['spec'].get(field) != expected['spec'][field]:
            sys.exit('Application source binding differs from reviewed source.')
    if expected['kind'] == 'Kustomization' and any(k in actual['spec'] for k in ('decryption','postBuild','kubeConfig','components','patches')):
        sys.exit('Application source has an unapproved reconciliation capability.')
    if not expected['spec']['suspend'] and not ready(actual):
        sys.exit('Enrolled application source has not reported current Ready.')

if units[1]['spec']['suspend']:
    print('Application boundary observations passed: controls installed; enrollment suspended. No runtime, storage, database or delivery acceptance claimed.')
else:
    for name in ('cv-releases','cv-requests','cv-artifacts'):
        claim=read('get','persistentvolumeclaim',name,'-n','career-ops','-o','json')
        if claim.get('status',{}).get('phase') != 'Bound' or claim['spec'].get('storageClassName') != 'career-ops-retain':
            sys.exit('An enrolled retained claim is not Bound to the approved class.')
        pv=read('get','persistentvolume',claim['spec']['volumeName'],'-o','json')
        if pv['spec'].get('persistentVolumeReclaimPolicy') != 'Retain':
            sys.exit('An enrolled volume lacks Retain reclamation.')
    print('Application source and retained-volume observations passed. Native network, mounts, credentials, signal correctness and recovery need separate acceptance.')
PY
