"""Bounded, TLS verified OpenBao HTTP transport for guarded operator workflows."""

import json
import ssl
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from .configuration import SafeError, strict_json


class ReadFailure(SafeError):
    pass


class AmbiguousWrite(SafeError):
    pass


class MalformedResponse(SafeError):
    pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class BaoClient:
    """One bounded request per call; token material is never stored on the client."""

    def __init__(self, base_url: str, *, timeout: float = 5, max_bytes: int = 1_048_576,
                 opener=None, ssl_context=None):
        parsed = urlsplit(base_url)
        if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
                or parsed.path not in ('', '/') or parsed.query or parsed.fragment
                or not 0 < timeout <= 30 or not 0 < max_bytes <= 4_194_304):
            raise SafeError('invalid-source')
        self.base_url = base_url.rstrip('/')
        self.timeout = timeout
        self.max_bytes = max_bytes
        self.ssl_context = ssl_context or ssl.create_default_context()
        if self.ssl_context.verify_mode != ssl.CERT_REQUIRED or not self.ssl_context.check_hostname:
            raise SafeError('invalid-source')
        self._open = opener or urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=self.ssl_context), _NoRedirect()).open

    def read(self, path: str, *, token: str | None = None, list_request: bool = False) -> object:
        return self._request('LIST' if list_request else 'GET', path, None, token)

    def post(self, path: str, payload: dict, *, token: str | None = None) -> object:
        if not isinstance(payload, dict):
            raise SafeError('invalid-source')
        return self._request('POST', path, json.dumps(payload).encode('utf-8'), token)

    def _request(self, method: str, path: str, body: bytes | None, token: str | None) -> object:
        if (not isinstance(path, str) or not path or path.startswith('/') or '..' in path.split('/')
                or '?' in path or '#' in path or '//' in path):
            raise SafeError('invalid-source')
        url = f'{self.base_url}/v1/{path}'
        headers = {'Accept': 'application/json'}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        if token is not None:
            headers['X-Vault-Token'] = token
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self._open(request, timeout=self.timeout) as response:
                if response.geturl() != url:
                    raise ReadFailure('invalid-response')
                if response.status < 200 or response.status >= 300:
                    raise ReadFailure('read-denied' if response.status == 403 else 'invalid-response')
                length = response.headers.get('Content-Length')
                if length is not None:
                    try:
                        parsed_length = int(length)
                    except (TypeError, ValueError, OverflowError):
                        raise MalformedResponse('invalid-response') from None
                    if parsed_length < 0 or parsed_length > self.max_bytes:
                        raise MalformedResponse('invalid-response')
                data = response.read(self.max_bytes + 1)
                if len(data) > self.max_bytes:
                    raise MalformedResponse('invalid-response')
                try:
                    return strict_json(data, 'invalid-response')
                except SafeError:
                    raise MalformedResponse('invalid-response') from None
        except urllib.error.HTTPError as error:
            if method == 'POST':
                raise AmbiguousWrite('ambiguous-write') from None
            raise ReadFailure('read-denied' if error.code == 403 else 'invalid-response') from None
        except (TimeoutError, OSError, urllib.error.URLError, ValueError, OverflowError):
            if method == 'POST':
                raise AmbiguousWrite('ambiguous-write') from None
            raise ReadFailure('timeout') from None
        except SafeError:
            raise
