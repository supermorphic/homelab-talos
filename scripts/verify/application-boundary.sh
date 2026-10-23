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

rendered='\n---\n'.join(
    subprocess.check_output(['kustomize','build','kubernetes/apps/applications/career-ops/'+root],text=True)
    for root in ('platform','fixture-storage'))
for expected in yaml.safe_load_all(rendered):
    actual=get(expected)
    if controlled(expected) != controlled(actual):
        sys.exit('An installed application control differs from the reviewed source: '+expected['kind']+'/'+expected['metadata']['name'])
    if expected['kind'] == 'Namespace' and any(actual['metadata'].get('labels',{}).get(k) != v for k,v in expected['metadata']['labels'].items()):
        sys.exit('Application namespace restriction labels differ from source.')
    if expected['kind'] == 'CiliumNetworkPolicy' and not any(
        c.get('type') == 'Valid' and c.get('status') == 'True'
        for c in actual.get('status',{}).get('conditions',[])):
        sys.exit('An installed Cilium policy has not reported valid: '+expected['metadata']['name'])
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
    if not expected['spec']['suspend'] and not ready(actual):
        sys.exit('Application platform has not reported Ready for its current generation.')

connection=list(yaml.safe_load_all(subprocess.check_output(['kustomize','build','kubernetes/apps/applications/career-ops/connection'],text=True)))
enrolled={}
for expected in connection:
    # Credential delivery has separate acceptance; the observer never reads Secrets.
    if expected['kind'] == 'Secret':
        continue
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
    enrolled[expected['kind']]=actual

if units[1]['spec']['suspend']:
    print('Application boundary observations passed: controls installed; enrollment suspended. No runtime, storage, database or delivery acceptance claimed.')
else:
    revision=enrolled['GitRepository'].get('status',{}).get('artifact',{}).get('revision')
    if not revision or enrolled['Kustomization'].get('status',{}).get('lastAppliedRevision') != revision:
        sys.exit('Application has not applied the current source revision.')
    for name,size in (('cv-releases','8Gi'),('cv-requests','16Gi'),('cv-artifacts','32Gi')):
        claim=read('get','persistentvolumeclaim',name,'-n','career-ops','-o','json')
        if (claim.get('status',{}).get('phase') != 'Bound' or claim['spec'].get('storageClassName') != 'career-ops-retain'
            or claim['spec'].get('accessModes') != ['ReadWriteMany'] or claim['spec'].get('volumeMode') != 'Filesystem'
            or claim['spec'].get('resources',{}).get('requests',{}).get('storage') != size
            or claim['metadata'].get('annotations',{}).get('kustomize.toolkit.fluxcd.io/prune') != 'disabled'
            or claim['metadata'].get('ownerReferences')):
            sys.exit('An enrolled retained claim lacks its approved Bound, RWX, size or retention controls.')
        pv=read('get','persistentvolume',claim['spec']['volumeName'],'-o','json')
        if (pv['spec'].get('persistentVolumeReclaimPolicy') != 'Retain' or pv['spec'].get('storageClassName') != 'career-ops-retain'
            or pv['spec'].get('claimRef',{}).get('uid') != claim['metadata']['uid'] or pv['spec'].get('csi',{}).get('driver') != 'driver.longhorn.io'):
            sys.exit('An enrolled volume lacks its owned Longhorn Retain binding.')
        print('Retained claim '+name+': '+claim['metadata']['uid'])
    def observe_smoke(name, account, container, message, source_owned=False):
        job=read('get','job',name,'-n','career-ops','-o','json')
        if source_owned and any(job['metadata'].get('labels',{}).get(k) != v for k,v in {
            'kustomize.toolkit.fluxcd.io/name':'career-ops-apps',
            'kustomize.toolkit.fluxcd.io/namespace':'career-ops',
        }.items()):
            sys.exit('Application '+name+' lacks its current source ownership.')
        if job.get('status',{}).get('succeeded') != 1 or not any(
            c.get('type') == 'Complete' and c.get('status') == 'True' for c in job.get('status',{}).get('conditions',[])):
            sys.exit('Application '+name+' has not completed successfully.')
        pods=read('get','pods','-n','career-ops','-l','batch.kubernetes.io/job-name='+name,'-o','json')['items']
        succeeded=[]
        for pod in pods:
            if not any(o.get('apiVersion') == 'batch/v1' and o.get('kind') == 'Job' and o.get('name') == name
                       and o.get('uid') == job['metadata']['uid'] and o.get('controller') is True
                       for o in pod['metadata'].get('ownerReferences',[])):
                continue
            statuses=pod.get('status',{}).get('containerStatuses',[])
            terminated=statuses[0].get('state',{}).get('terminated',{}) if len(statuses) == 1 else {}
            if (pod['metadata'].get('namespace') == 'career-ops' and pod.get('status',{}).get('phase') == 'Succeeded'
                and pod['spec'].get('serviceAccountName') == account and pod['spec'].get('automountServiceAccountToken') is False
                and len(statuses) == 1 and statuses[0].get('name') == container
                and terminated.get('exitCode') == 0 and terminated.get('message','').strip() == message):
                succeeded.append(pod)
        if len(succeeded) != 1:
            sys.exit('Application '+name+' lacks its current owned tokenless Pod with exit0 and '+message+'.')
        print('Application '+name+': passed; current Job-owned tokenless Pod exited0 with '+message+'.')

    inventory=enrolled['Kustomization'].get('status',{}).get('inventory',{}).get('entries',[])
    if any(e.get('id') == 'career-ops_application-json-smoke_batch_Job' and e.get('v') == 'v1' for e in inventory):
        observe_smoke('application-json-smoke','career-ops-service','json-check','application-json-ok',source_owned=True)
    else:
        print('Second non-rendering workload is not selected by the current application inventory; acceptance pending.')
    print('Application source revision '+revision+'; retained-volume observations passed. Runtime, credentials, signal correctness and recovery need separate acceptance.')
PY
