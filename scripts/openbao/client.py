"""Bounded, TLS verified OpenBao HTTP transport for guarded operator workflows."""

import http.client
import json
import ssl
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from .configuration import SafeError, strict_json


class ReadFailure(SafeError):
    pass


class NotFound(ReadFailure):
    pass


class AmbiguousWrite(SafeError):
    def __init__(self, code: str = 'ambiguous-write', *, http_status: int | None = None):
        super().__init__(code)
        self.http_status = http_status if type(http_status) is int and 300 <= http_status <= 599 else None


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
        self.consistency_index = None
        self.timeout = timeout
        self.max_bytes = max_bytes
        self.ssl_context = ssl_context or ssl.create_default_context()
        if self.ssl_context.verify_mode != ssl.CERT_REQUIRED or not self.ssl_context.check_hostname:
            raise SafeError('invalid-source')
        self._open = opener or urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=self.ssl_context), _NoRedirect()).open

    def require_consistency(self, index):
        """Carry opaque OpenBao storage state across a verified client handoff."""
        if (not isinstance(index, str) or not 0 < len(index) <= 4096
                or any(not 32 <= ord(character) < 127 for character in index)):
            raise MalformedResponse('invalid-response')
        self.consistency_index = index

    def read(self, path: str, *, token: str | None = None, list_request: bool = False) -> object:
        return self._request('LIST' if list_request else 'GET', path, None, token)

    def post(self, path: str, payload: dict, *, token: str | None = None) -> object:
        if not isinstance(payload, dict):
            raise SafeError('invalid-source')
        return self._request('POST', path, json.dumps(payload).encode('utf-8'), token)

    def delete(self, path: str, *, token: str | None = None) -> object:
        return self._request("DELETE", path, None, token)

    def _request(self, method: str, path: str, body: bytes | None, token: str | None) -> object:
        if (not isinstance(path, str) or not path or path.startswith('/') or '..' in path.split('/')
                or '?' in path or '#' in path or '//' in path):
            raise SafeError('invalid-source')
        url = f'{self.base_url}/v1/{path}'
        headers = {'Accept': 'application/json'}
        if self.consistency_index is not None:
            headers['X-Vault-Index'] = self.consistency_index
            headers['X-Vault-Inconsistent'] = 'forward-active-node'
        if body is not None:
            headers['Content-Type'] = 'application/json'
        if token is not None:
            headers['X-Vault-Token'] = token
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            # Raft initialization can finish after the ordinary API deadline;
            # the one-time response contains the only initial recovery material.
            timeout = 30 if method in {'POST', 'DELETE'} and path == 'sys/init' else self.timeout
            with self._open(request, timeout=timeout) as response:
                if response.geturl() != url:
                    raise ReadFailure('invalid-response')
                if response.status < 200 or response.status >= 300:
                    if method in {'POST', 'DELETE'}:
                        raise AmbiguousWrite('ambiguous-write', http_status=response.status)
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
                index = response.headers.get('X-Vault-Index')
                if index is not None:
                    self.require_consistency(index)
                if method in {'POST', 'DELETE'} and response.status == 204 and not data:
                    return {}
                try:
                    return strict_json(data, 'invalid-response')
                except SafeError:
                    raise MalformedResponse('invalid-response') from None
        except urllib.error.HTTPError as error:
            if method in {'POST', 'DELETE'}:
                raise AmbiguousWrite('ambiguous-write', http_status=error.code) from None
            if error.code == 404:
                raise NotFound('invalid-response') from None
            raise ReadFailure('read-denied' if error.code == 403 else 'invalid-response') from None
        except (TimeoutError, OSError, urllib.error.URLError, http.client.HTTPException, ValueError, OverflowError):
            if method in {'POST', 'DELETE'}:
                raise AmbiguousWrite('ambiguous-write') from None
            raise ReadFailure('timeout') from None
        except SafeError:
            raise
