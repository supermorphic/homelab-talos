#!/usr/bin/env python3
"""Probe only the fixed synthetic application, using its retained private credential."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import psycopg
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lib'))
from automation_data_client import (
    PrivateFileError,
    clear_pg_environment,
    private_database_tunnel,
    validate_private_directory,
    validate_private_file,
    validate_service_profile,
    validate_session_identity,
    write_private_file_exclusive,
)

DATABASE = 'automation_data_acceptance'
APPLICATION = 'interview'
ROLE = 'app_' + hashlib.md5(f'{DATABASE}:{APPLICATION}'.encode(),
                           usedforsecurity=False).hexdigest() + '_integration'
REPOSITORY = Path(__file__).resolve().parents[3]
CREDENTIAL_FIXTURE = 'nocodb-restore-application-credential'
CREDENTIAL_OWNER = 'homelab-talos/credential-run'


def run_identity(run_id: str) -> tuple[int, str]:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', run_id):
        raise ValueError('invalid_acceptance_run')
    return int(hashlib.md5(run_id.encode(), usedforsecurity=False).hexdigest()[:15], 16), \
        'acceptance:' + run_id


def private_root() -> Path:
    root = validate_private_directory(Path(os.environ.get('AUTOMATION_DATA_LOGIN_DIRECTORY', '')))
    if root.resolve() == REPOSITORY or REPOSITORY in root.resolve().parents:
        raise PrivateFileError('credential_directory_inside_checkout')
    return root


def retained_profile() -> tuple[int, str]:
    root = private_root()
    directory = validate_private_directory(validate_private_directory(root / DATABASE) / APPLICATION)
    binding = json.loads(validate_private_file(directory / 'binding.json').read_text())
    port = binding.get('localPort')
    if binding.get('domain') != DATABASE or binding.get('application') != APPLICATION or \
            binding.get('database') != DATABASE or binding.get('schema') != 'app' or \
            binding.get('role') != ROLE or type(port) is not int or not 1024 <= port <= 65535 or \
            type(binding.get('credentialGeneration')) is not int or binding['credentialGeneration'] < 1:
        raise PrivateFileError('synthetic_application_binding_invalid')
    profile = validate_service_profile(directory / 'service.conf',
                                       f'automation_data_{DATABASE}_{ROLE}', DATABASE, ROLE, port)
    version = validate_private_directory(directory / f"generation-{binding['credentialGeneration']}")
    if Path(profile['passfile']).parent != version:
        raise PrivateFileError('synthetic_credential_generation_invalid')
    return port, profile['password']


def require_denial(error: Exception) -> None:
    if getattr(error, 'sqlstate', None) != '42501':
        raise ValueError('privilege_denial_required') from None


def probe_connection(connection: psycopg.Connection, run_id: str) -> None:
    identity, value = run_identity(run_id)
    validate_session_identity(connection, DATABASE, ROLE)
    with connection.cursor() as cursor:
        cursor.execute('SELECT app.record_integration_fact(%s,%s)', (identity, value))
        cursor.execute('SELECT fact FROM app.integration_facts WHERE id=%s', (identity,))
        if cursor.fetchone() != (value,):
            raise ValueError('application_write_read_failed')
    # The savepoint rolls back each denied operation without hiding a wrong SQLSTATE.
    for query in (
        'SELECT * FROM app.withheld_bookkeeping', 'SELECT app.withheld_admin()',
        "INSERT INTO app.integration_facts VALUES (-491,'denied')",
        'SELECT * FROM extra_read.visible_facts',
        'SET ROLE automation_data_acceptance_owner',
    ):
        try:
            with connection.transaction(), connection.cursor() as cursor:
                cursor.execute(query)
        except psycopg.Error as error:
            require_denial(error)
        else:
            raise ValueError('forbidden_operation_permitted')


def probe_live(kubeconfig: Path, run_id: str) -> None:
    run_identity(run_id)
    port, password = retained_profile()
    with private_database_tunnel(kubeconfig, port), clear_pg_environment():
        options = {'host': '127.0.0.1', 'port': port, 'dbname': DATABASE, 'user': ROLE,
                   'connect_timeout': 5, 'sslmode': 'disable',
                   'options': '-c statement_timeout=5000'}
        try:
            with psycopg.connect(**options, password='acceptance-wrong-password'):
                pass
        except psycopg.OperationalError:
            pass
        else:
            raise ValueError('unrelated_password_accepted')
        with psycopg.connect(**options, password=password) as connection:
            probe_connection(connection, run_id)


def client_command(host: str, run_id: str) -> str:
    run_identity(run_id)
    if host != 'restore-postgresql' and not re.fullmatch(r'nc-restore-[a-f0-9]{12}-db', host):
        raise ValueError('isolated_database_required')
    program = (REPOSITORY / 'kubernetes/apps/automation-data/postgresql/app/test-helpers/nocodb-application-probe.sh').read_text()
    return f"PGHOST='{host}'\nRUN_ID='{run_id}'\nexport PGHOST RUN_ID\n" + program


def write_restore_manifests(directory: Path, run_hash: str, run_id: str, password: str) -> None:
    if not re.fullmatch(r'[a-f0-9]{12}', run_hash):
        raise ValueError('isolated_run_hash_required')
    run_identity(run_id)
    directory = validate_private_directory(directory)
    if directory.resolve() == REPOSITORY or REPOSITORY in directory.resolve().parents:
        raise PrivateFileError('credential_artifact_inside_checkout')
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', password):
        raise PrivateFileError('retained_password_invalid')
    prefix = f'nc-restore-{run_hash}'
    labels = {'homelab-talos/test': 'nocodb-restore-drill', 'homelab-talos/run-id': run_hash,
              'homelab-talos/role': 'restore'}
    secret_name, job_name = 'nocodb-restore-application-credential', prefix + '-app-probe'
    credential = {'runHash': run_hash, 'runId': run_id,
                  'pgpass': f'{prefix}-db:5432:{DATABASE}:{ROLE}:{password}\n'}
    job = {'apiVersion': 'batch/v1', 'kind': 'Job',
           'metadata': {'name': job_name, 'namespace': 'automation-data', 'labels': labels},
           'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': 180, 'template': {
               'metadata': {'labels': labels}, 'spec': {
                   'restartPolicy': 'Never', 'automountServiceAccountToken': False,
                   'securityContext': {'runAsNonRoot': True, 'runAsUser': 70,
                                       'runAsGroup': 70, 'fsGroup': 70,
                                       'seccompProfile': {'type': 'RuntimeDefault'}},
                   'containers': [{'name': 'application-probe',
                                   'image': 'postgres:17.11-alpine3.24',
                                   'command': ['/bin/sh', '-eu', '/helpers/nocodb-application-probe.sh'],
                                   'env': [{'name': 'PGHOST', 'value': prefix + '-db'},
                                           {'name': 'RUN_ID', 'value': run_id}],
                                   'securityContext': {'allowPrivilegeEscalation': False,
                                                       'readOnlyRootFilesystem': True,
                                                       'capabilities': {'drop': ['ALL']}},
                                   'resources': {'requests': {'cpu': '10m', 'memory': '32Mi'},
                                                 'limits': {'memory': '128Mi'}},
                                   'volumeMounts': [{'name': 'credential',
                                                     'mountPath': '/credentials', 'readOnly': True},
                                                    {'name': 'scratch', 'mountPath': '/tmp'},
                                                    {'name': 'helpers', 'mountPath': '/helpers', 'readOnly': True}]}],
                   'volumes': [{'name': 'credential', 'secret': {'secretName': secret_name,
                                                                'defaultMode': 0o400}},
                               {'name': 'scratch', 'emptyDir': {}},
                               {'name': 'helpers', 'configMap': {'name': 'automation-data-test-helpers-v1'}}]}}}}
    write_private_file_exclusive(directory / 'application-probe.yaml',
                                 yaml.safe_dump(job, sort_keys=False).encode())
    write_private_file_exclusive(directory / 'application-credential.json',
                                 json.dumps(credential).encode())


def credential_directory(directory: Path, run_hash: str) -> Path:
    if not re.fullmatch(r'[a-f0-9]{12}', run_hash):
        raise PrivateFileError('fixture_ownership_invalid')
    directory = validate_private_directory(directory)
    if directory.resolve() == REPOSITORY or REPOSITORY in directory.resolve().parents:
        raise PrivateFileError('credential_artifact_inside_checkout')
    return directory


def fixture_command(kubeconfig: Path, *arguments: str, payload: object = None) -> str:
    # Both API bodies and errors can contain credentials. Keep them out of logs.
    result = subprocess.run(['kubectl', '--kubeconfig', str(kubeconfig), '-n',
                             'automation-data', *arguments], capture_output=True, text=True,
                            input=None if payload is None else json.dumps(payload), check=False)
    if result.returncode:
        raise PrivateFileError('credential_fixture_request_failed')
    return result.stdout


def read_credential_fixture(kubeconfig: Path) -> dict:
    fixture = json.loads(fixture_command(kubeconfig, 'get', 'secret', CREDENTIAL_FIXTURE,
                                        '-o', 'json'))
    metadata = fixture.get('metadata', {})
    if fixture.get('kind') != 'Secret' or fixture.get('type') != 'Opaque' or \
            metadata.get('name') != CREDENTIAL_FIXTURE or \
            metadata.get('namespace') != 'automation-data' or \
            metadata.get('labels', {}).get('homelab-talos/test') != 'nocodb-restore-extension' or \
            metadata.get('annotations', {}).get('kustomize.toolkit.fluxcd.io/ssa') != 'IfNotPresent' or \
            not metadata.get('uid') or not metadata.get('resourceVersion') or \
            metadata.get('deletionTimestamp') or \
            not isinstance(metadata.get('annotations', {}).get(CREDENTIAL_OWNER), str) or \
            not isinstance(fixture.get('data', {}), dict):
        raise PrivateFileError('fixture_ownership_invalid')
    return fixture


def patch_credential_fixture(kubeconfig: Path, fixture: dict, run_hash: str, data: dict) -> None:
    metadata = fixture['metadata']
    patch = [
        {'op': 'test', 'path': '/metadata/uid', 'value': metadata['uid']},
        {'op': 'test', 'path': '/metadata/resourceVersion', 'value': metadata['resourceVersion']},
        {'op': 'replace' if 'data' in fixture else 'add', 'path': '/data', 'value': data},
        {'op': 'replace', 'path': '/metadata/annotations/homelab-talos~1credential-run',
         'value': run_hash},
    ]
    fixture_command(kubeconfig, 'patch', 'secret', CREDENTIAL_FIXTURE, '--type=json',
                    '--patch-file=/dev/stdin', '-o', 'name', payload=patch)


def fill_restore_credential(kubeconfig: Path, directory: Path, run_hash: str) -> None:
    directory = credential_directory(directory, run_hash)
    credential = json.loads(validate_private_file(directory / 'application-credential.json').read_text())
    if credential.get('runHash') != run_hash or \
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', credential.get('runId', '')) or \
            not re.fullmatch(rf'nc-restore-{run_hash}-db:5432:{DATABASE}:{ROLE}:'
                             r'[A-Za-z0-9_-]{32,256}\n', credential.get('pgpass', '')):
        raise PrivateFileError('fixture_ownership_invalid')
    fixture = read_credential_fixture(kubeconfig)
    metadata = fixture['metadata']
    owner = metadata['annotations'][CREDENTIAL_OWNER]
    if owner not in ('', run_hash) or (not owner and fixture.get('data')):
        raise PrivateFileError('fixture_ownership_invalid')
    record = {'uid': metadata['uid'], 'runHash': run_hash}
    ledger = directory / 'application-credential-owner.json'
    if ledger.exists():
        if json.loads(validate_private_file(ledger).read_text()) != record:
            raise PrivateFileError('fixture_ownership_invalid')
    else:
        # Record before PATCH so interrupted or uncertain writes remain cleanable.
        write_private_file_exclusive(ledger, json.dumps(record).encode())
    patch_credential_fixture(kubeconfig, fixture, run_hash,
                             {'pgpass': base64.b64encode(credential['pgpass'].encode()).decode()})


def clear_restore_credential(kubeconfig: Path, directory: Path, run_hash: str) -> None:
    directory = credential_directory(directory, run_hash)
    ledger = directory / 'application-credential-owner.json'
    if not ledger.exists():
        return
    record = json.loads(validate_private_file(ledger).read_text())
    fixture = read_credential_fixture(kubeconfig)
    metadata = fixture['metadata']
    owner = metadata['annotations'][CREDENTIAL_OWNER]
    if record != {'uid': metadata['uid'], 'runHash': run_hash} or \
            owner not in ('', run_hash) or (not owner and fixture.get('data')):
        raise PrivateFileError('fixture_ownership_invalid')
    if owner:
        patch_credential_fixture(kubeconfig, fixture, '', {})


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == 'check-root':
        private_root()
    elif len(sys.argv) == 2 and sys.argv[1] == 'check-profile':
        retained_profile()
    elif len(sys.argv) == 4 and sys.argv[1] == 'live':
        probe_live(Path(sys.argv[2]), sys.argv[3])
        print('application_acceptance=passed')
    elif len(sys.argv) == 5 and sys.argv[1] == 'restore-manifests':
        _, password = retained_profile()
        write_restore_manifests(Path(sys.argv[2]), sys.argv[3], sys.argv[4], password)
    elif len(sys.argv) == 5 and sys.argv[1] in ('fill-restore-credential', 'clear-restore-credential'):
        operation = fill_restore_credential if sys.argv[1] == 'fill-restore-credential' else clear_restore_credential
        operation(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
    elif len(sys.argv) == 4 and sys.argv[1] == 'disposable-command':
        write_private_file_exclusive(Path(sys.argv[3]),
                                     client_command('restore-postgresql', sys.argv[2]).encode())
    else:
        raise ValueError('invalid_acceptance_arguments')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, psycopg.Error, RuntimeError):
        print('The fixed application acceptance probe failed.', file=sys.stderr)
        sys.exit(1)
