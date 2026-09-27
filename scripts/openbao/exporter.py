"""Fixed read-only OpenBao collector; Prometheus receives sanitized evidence only."""
import hashlib
import http.client
import json
import math
import socket
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from .configuration import Difference, SafeError, load_document, strict_json
from .drift import sanitize
from .verify import INVENTORY_ENDPOINTS, compare_configuration

DESIRED = Path('/desired/desired.json')
PEERS = tuple(f'openbao-{i}.openbao-internal.openbao.svc' for i in range(3))
SERVER_NAME = 'openbao.lab.supermorphic.com'
METRIC = 'openbao_configuration_observation'
RUNTIME_FILES = ('__init__.py', 'configuration.py', 'drift.py', 'verify.py', 'exporter.py')
MAX_AGE = 300


def source_digest(desired):
    """Hash exact mounted inputs, including collector/comparator implementation."""
    files = [('desired.json', desired), *[(f'policies/{p.name}', p) for p in
             sorted((desired.parent / 'policies').glob('*.json'))],
             *[(f'code/{name}', Path(__file__).parent / name) for name in RUNTIME_FILES]]
    digest = hashlib.sha256()
    for name, path in files:
        data = path.read_bytes()
        digest.update(name.encode() + b'\0' + str(len(data)).encode() + b'\0' + data)
    return digest.hexdigest()


def checked_differences(items, desired):
    if not isinstance(items, list) or len(items) > 512:
        raise SafeError('invalid-response')
    output = []
    for item in items:
        if not isinstance(item, dict) or not set(item) <= {'kind', 'name', 'field', 'state', 'count'}:
            raise SafeError('invalid-response')
        if 'count' in item:
            count = item['count']
            if (set(item) != {'kind', 'state', 'count'} or item['state'] != 'unexpected'
                    or type(count) is not int or not 1 <= count <= 10000):
                raise SafeError('invalid-response')
            checked = sanitize([Difference(item['kind'], None, None, 'unexpected')], desired)['differences'][0]
            checked['count'] = count
        else:
            checked = sanitize([Difference(item['kind'], item.get('name'), item.get('field'), item['state'])], desired)['differences'][0]
        if checked != item:
            raise SafeError('invalid-response')
        output.append(checked)
    return output


def metric_rows(result, digest, health, collected, *, desired=None):
    desired = desired or DESIRED
    items = checked_differences(result['differences'], desired)
    if result['status'] not in {'pass', 'drift', 'inaccessible'} or health not in {'ready', 'inaccessible'}:
        raise SafeError('invalid-response')
    if (result['status'] == 'pass' and items) or (result['status'] == 'drift' and not items):
        raise SafeError('invalid-response')
    labels = {'digest': digest, 'kind': 'summary', 'name': '', 'field': '', 'state': result['status'],
                  'count': str(len(items)), 'health': health}
    rows = [(labels, collected)]
    for item in items:
        rows.append(({'digest': digest, 'kind': item['kind'], 'name': item.get('name', ''),
                         'field': item.get('field', ''), 'state': item['state'],
                         'count': str(item.get('count', 0)), 'health': ''}, collected))
    return rows


def decode_observation(response, desired, *, now=None):
    """Accept one recent, complete scrape of evidence for these exact inputs."""
    now = time.time() if now is None else now
    try:
        if response['status'] != 'success' or response['data']['resultType'] != 'vector':
            raise SafeError('invalid-response')
        rows = response['data']['result']
        if not isinstance(rows, list) or not 1 <= len(rows) <= 513:
            raise SafeError('invalid-response')
        digest = source_digest(desired)
        summaries, differences, times, scrape_times, fingerprints = [], [], set(), set(), set()
        for row in rows:
            labels = row['metric']; stamp, value = map(float, row['value'])
            if (not math.isfinite(value) or not math.isfinite(stamp)
                    or not 0 <= now - value <= MAX_AGE or not 0 <= now - stamp <= 120
                    or labels['__name__'] != METRIC or labels['namespace'] != 'openbao'
                    or labels['service'] != 'openbao-config-reader' or labels['endpoint'] != 'metrics'
                    or labels['digest'] != digest):
                raise SafeError('source-mismatch')
            times.add(value); scrape_times.add(stamp)
            key = tuple(labels[k] for k in ('kind', 'name', 'field', 'state', 'count', 'health'))
            if key in fingerprints:
                raise SafeError('invalid-response')
            fingerprints.add(key)
            if labels['kind'] == 'summary':
                summaries.append(labels)
            else:
                item = {'kind': labels['kind'], 'state': labels['state']}
                if labels['name']: item['name'] = labels['name']
                if labels['field']: item['field'] = labels['field']
                if labels['count'] != '0': item['count'] = int(labels['count'])
                if labels['health'] != '': raise SafeError('invalid-response')
                differences.append(item)
        if len(summaries) != 1 or len(times) != 1 or len(scrape_times) != 1:
            raise SafeError('invalid-response')
        summary = summaries[0]
        if summary['name'] or summary['field'] or summary['count'] != str(len(differences)):
            raise SafeError('invalid-response')
        result = {'status': summary['state'], 'differences': differences}
        metric_rows(result, digest, summary['health'], next(iter(times)), desired=desired)
        return {**result, 'health': summary['health'], 'collected_at': next(iter(times)), 'digest': digest}
    except (KeyError, TypeError, ValueError, IndexError, OSError):
        raise SafeError('invalid-response') from None


def health_quorum(statuses: dict, raft: dict) -> bool:
    try:
        expected = {'openbao-0', 'openbao-1', 'openbao-2'}
        if set(statuses) != expected:
            return False
        cluster_ids = {status['cluster_id'] for status in statuses.values()}
        if (len(cluster_ids) != 1 or not all(isinstance(value, str) and value for value in cluster_ids)
                or not all(status['initialized'] is True and status['sealed'] is False
                           and status['ha_enabled'] is True and status['storage_type'] == 'raft'
                           and type(status.get('is_self', False)) is bool for status in statuses.values())):
            return False
        active = {name for name, status in statuses.items() if status.get('is_self', False)}
        servers = raft['config']['servers']
        if not isinstance(servers, list) or len(servers) != 3:
            return False
        identifiers = {server['node_id'] for server in servers}
        leaders = {server['node_id'] for server in servers if server['leader'] is True}
        return (identifiers == expected and len(identifiers) == 3
                and all(server['voter'] is True and type(server['leader']) is bool for server in servers)
                and active == leaders and len(active) == 1)
    except (AttributeError, TypeError, KeyError, ValueError):
        return False



class PeerConnection(http.client.HTTPSConnection):
    def __init__(self, peer):
        super().__init__(peer, 8200, timeout=5, context=ssl.create_default_context())

    def connect(self):
        raw = socket.create_connection((self.host, self.port), self.timeout)
        try:
            self.sock = self._context.wrap_socket(raw, server_hostname=SERVER_NAME)
        except BaseException:
            raw.close()
            raise


class ConfigurationReader:
    """Only fixed health, login, source-owned reads and self-revocation requests."""
    def __init__(self, desired, jwt_path):
        document = load_document(desired)
        self.reads = {spec.path for spec in document['objects']} | {'sys/storage/raft/configuration'}
        self.jwt_path = jwt_path
        self.token = None
        self.peer = None
        self.deadline = time.monotonic() + 120

    def exchange(self, peer, method, path, payload=None):
        if peer not in PEERS or time.monotonic() > self.deadline:
            raise SafeError('timeout')
        connection = PeerConnection(peer)
        try:
            headers = {'Accept': 'application/json', 'X-Vault-No-Request-Forwarding': 'true'}
            if self.token: headers['X-Vault-Token'] = self.token
            body = json.dumps(payload).encode() if payload is not None else None
            if body is not None: headers['Content-Type'] = 'application/json'
            connection.request(method, '/v1/' + path, body=body, headers=headers)
            response = connection.getresponse()
            raw = response.read(1_048_577)
            if response.status not in (200, 204) or len(raw) > 1_048_576:
                raise SafeError('read-denied')
            return strict_json(raw, 'invalid-response') if raw else {}
        except (OSError, http.client.HTTPException):
            raise SafeError('timeout') from None
        finally:
            connection.close()

    def login(self):
        statuses = {}
        for i, peer in enumerate(PEERS):
            seal = self.exchange(peer, 'GET', 'sys/seal-status')
            leader = self.exchange(peer, 'GET', 'sys/leader')
            statuses[f'openbao-{i}'] = {**seal, **leader}
        active = [i for i, status in enumerate(statuses.values()) if status.get('is_self') is True]
        if len(active) != 1:
            raise SafeError('invalid-response')
        self.peer = PEERS[active[0]]
        response = self.exchange(self.peer, 'POST', 'auth/homelab-jwt/login',
                                 {'role': 'openbao-config-reader', 'jwt': self.jwt_path.read_text().strip()})
        auth = response['auth']
        if (not isinstance(auth.get('client_token'), str) or not auth['client_token']
                or auth.get('policies') != ['openbao-config-reader']
                or type(auth.get('lease_duration')) is not int or not 0 < auth['lease_duration'] <= 300):
            raise SafeError('authentication-failed')
        self.token = auth['client_token']
        raft = self.request('GET', 'sys/storage/raft/configuration')
        return 'ready' if health_quorum(statuses, raft) else 'inaccessible'

    def request(self, method, path):
        if not ((method == 'GET' and path in self.reads | {'sys/auth', 'sys/mounts'})
                or (method == 'LIST' and path in set(INVENTORY_ENDPOINTS.values()) - {'sys/auth', 'sys/mounts'})):
            raise SafeError('invalid-source')
        if not self.token or not self.peer: raise SafeError('authentication-failed')
        result = self.exchange(self.peer, method, path)
        if not isinstance(result.get('data'), dict): raise SafeError('invalid-response')
        return result['data']

    def close(self):
        if self.token:
            try:
                self.exchange(self.peer, 'POST', 'auth/token/revoke-self', {})
            finally:
                self.token = None


def collect(desired, jwt_path, reader_factory=ConfigurationReader):
    reader = reader_factory(desired, jwt_path)
    try:
        health = reader.login()
        return compare_configuration(desired, reader), health
    except (SafeError, OSError, KeyError, TypeError, ValueError, IndexError):
        return {'status': 'inaccessible', 'differences': []}, 'inaccessible'
    finally:
        try: reader.close()
        except (SafeError, OSError): pass  # Session is also bounded by a five-minute TTL.


def render_metrics(rows):
    lines = [f'# TYPE {METRIC} gauge']
    for labels, value in rows:
        text = ','.join(f'{key}={json.dumps(item)}' for key, item in sorted(labels.items()))
        lines.append(f'{METRIC}{{{text}}} {value}')
    return ('\n'.join(lines) + '\n').encode()


def main():
    digest = source_digest(DESIRED)
    state = [b'']  # No success exists before the first complete collection.
    def poll():
        while True:
            result, health = collect(DESIRED, Path('/identity/token'))
            state[0] = render_metrics(metric_rows(result, digest, health, time.time(), desired=DESIRED))
            time.sleep(60)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/metrics':
                self.send_error(404); return
            body = state[0]
            self.send_response(200 if body else 503)
            self.send_header('Content-Type', 'text/plain; version=0.0.4')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *_args):
            pass
    threading.Thread(target=poll, daemon=True).start()
    HTTPServer(('0.0.0.0', 9399), Handler).serve_forever()


if __name__ == '__main__':
    main()
