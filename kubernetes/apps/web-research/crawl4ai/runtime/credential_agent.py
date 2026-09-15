#!/usr/bin/env python3
"""Cache Crawl4AI data credentials and serve Envoy ext_authz checks."""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import math
import random
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar, Protocol

DEFAULT_UPSTREAM_URL = "http://127.0.0.1:11235"
DEFAULT_AUTH_HOST = "127.0.0.1"
DEFAULT_AUTH_PORT = 9000
DEFAULT_MONITOR_HOST = "0.0.0.0"
DEFAULT_MONITOR_PORT = 9001
DEFAULT_INBOUND_REQUEST_TIMEOUT = 2.0
DEFAULT_INBOUND_WORKERS = 8


@dataclass(frozen=True)
class HTTPResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


@dataclass(frozen=True)
class AgentResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes
    content_type: str = "application/json"


@dataclass(frozen=True)
class _Credential:
    token: str
    expires_at: float
    renew_at: float
    generation: int
    last_validated_at: float
    invalidated: bool = False


class TransportFailure(Exception):
    """A credential-free, bounded reason for an HTTP transport failure."""

    def __init__(self, label: str):
        self.label = label
        super().__init__(label)


class _CandidateFailure(Exception):
    def __init__(self, label: str):
        self.label = label
        super().__init__(label)


class HTTPTransport(Protocol):
    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout: float,
        max_body_bytes: int,
    ) -> HTTPResponse: ...


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class UrllibTransport:
    """Small stdlib HTTP client with redirect, time, and body bounds."""

    def __init__(self, monotonic: Callable[[], float] = time.monotonic):
        self._opener = urllib.request.build_opener(_NoRedirectHandler())
        self._monotonic = monotonic

    def _read_bounded(self, response, max_body_bytes: int, deadline: float) -> bytes:
        content_length = response.headers.get("Content-Length")
        if content_length is not None:
            try:
                if int(content_length) > max_body_bytes:
                    raise TransportFailure("response_too_large")
            except ValueError as error:
                raise TransportFailure("invalid_response") from error
        chunks = []
        body_size = 0
        while True:
            remaining = deadline - self._monotonic()
            if remaining <= 0:
                raise TransportFailure("timeout")
            stream = getattr(response, "fp", None)
            raw = getattr(stream, "raw", None)
            response_socket = getattr(raw, "_sock", None)
            if response_socket is not None:
                response_socket.settimeout(remaining)
            chunk = response.read1(min(8192, max_body_bytes + 1 - body_size))
            if not chunk:
                break
            chunks.append(chunk)
            body_size += len(chunk)
            if body_size > max_body_bytes:
                raise TransportFailure("response_too_large")
        if self._monotonic() > deadline:
            raise TransportFailure("timeout")
        return b"".join(chunks)

    def request(
        self,
        method: str,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes | None,
        timeout: float,
        max_body_bytes: int,
    ) -> HTTPResponse:
        deadline = self._monotonic() + timeout
        request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
        try:
            with self._opener.open(request, timeout=timeout) as response:
                return HTTPResponse(
                    status=response.status,
                    headers={key.lower(): value for key, value in response.headers.items()},
                    body=self._read_bounded(response, max_body_bytes, deadline),
                )
        except urllib.error.HTTPError as error:
            if 300 <= error.code < 400:
                error.close()
                raise TransportFailure("redirect") from None
            try:
                body_bytes = self._read_bounded(error, max_body_bytes, deadline)
                headers_out = {key.lower(): value for key, value in error.headers.items()}
            finally:
                error.close()
            return HTTPResponse(error.code, headers_out, body_bytes)
        except TimeoutError:
            raise TransportFailure("timeout") from None
        except urllib.error.URLError as error:
            if isinstance(error.reason, TimeoutError):
                raise TransportFailure("timeout") from None
            raise TransportFailure("network_error") from None
        except OSError:
            raise TransportFailure("network_error") from None


class CredentialAgent:
    """Own one validated in-memory credential and its background lifecycle."""

    _KNOWN_REASONS: ClassVar[frozenset[str]] = frozenset(
        {
            "bootstrap_unavailable",
            "invalid_content_type",
            "invalid_issuer_response",
            "invalid_json",
            "invalid_jwt",
            "invalid_response",
            "issuer_4xx",
            "issuer_5xx",
            "network_error",
            "redirect",
            "response_too_large",
            "timeout",
            "validation_401",
            "validation_4xx",
            "validation_5xx",
        }
    )

    def __init__(
        self,
        *,
        upstream_url: str,
        admin_token_file: Path | str,
        subject: str,
        transport: HTTPTransport | None = None,
        clock: Callable[[], float] = time.time,
        random_source: Callable[[], float] = random.random,
        request_timeout: float = 5.0,
        max_response_bytes: int = 64 * 1024,
        max_schema_response_bytes: int = 2 * 1024 * 1024,
        expiry_margin: float = 30.0,
        validation_interval: float = 60.0,
        active_window: float = 300.0,
        retry_initial: float = 2.0,
        retry_max: float = 60.0,
        max_token_lifetime: float = 7200.0,
    ):
        if not subject or "@" not in subject:
            raise ValueError("subject must be a fixed email address")
        timing_values = (
            request_timeout,
            expiry_margin,
            validation_interval,
            active_window,
            retry_initial,
            retry_max,
            max_token_lifetime,
        )
        if not all(math.isfinite(value) for value in timing_values):
            raise ValueError("timing configuration must be finite")
        if request_timeout <= 0 or max_response_bytes <= 0 or max_schema_response_bytes <= 0:
            raise ValueError("HTTP bounds must be positive")
        parsed_upstream = urllib.parse.urlsplit(upstream_url)
        try:
            upstream_port = parsed_upstream.port
        except ValueError:
            upstream_port = None
        upstream_host = parsed_upstream.hostname
        is_loopback = upstream_host == "localhost"
        if upstream_host and not is_loopback:
            try:
                is_loopback = ipaddress.ip_address(upstream_host).is_loopback
            except ValueError:
                is_loopback = False
        if (
            parsed_upstream.scheme != "http"
            or not is_loopback
            or upstream_port is None
            or parsed_upstream.username is not None
            or parsed_upstream.password is not None
            or parsed_upstream.path not in ("", "/")
            or parsed_upstream.query
            or parsed_upstream.fragment
        ):
            raise ValueError("upstream URL must be an HTTP loopback origin with a port")
        self.upstream_url = upstream_url.rstrip("/")
        self.admin_token_file = Path(admin_token_file)
        self.subject = subject
        self.transport = transport or UrllibTransport()
        self.clock = clock
        self.random_source = random_source
        self.request_timeout = request_timeout
        self.max_response_bytes = max_response_bytes
        self.max_schema_response_bytes = max_schema_response_bytes
        self.expiry_margin = expiry_margin
        self.validation_interval = validation_interval
        self.active_window = active_window
        self.retry_initial = retry_initial
        self.retry_max = retry_max
        self.max_token_lifetime = max_token_lifetime

        self._lock = threading.Lock()
        self._operation_lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._worker: threading.Thread | None = None
        self._credential: _Credential | None = None
        self._generation = 0
        self._last_use_at: float | None = None
        self._last_validation_attempt_at: float | None = None
        self._last_refresh_success_at: float | None = None
        self._last_validation_success_at: float | None = None
        self._next_retry_at = 0.0
        self._retry_count = 0
        self._reason: str | None = None
        self._refresh_reason: str | None = None
        self._validation_reason: str | None = None
        self._failure_counters: dict[str, int] = {}

    def _usable(self, credential: _Credential | None, now: float) -> bool:
        return bool(
            credential
            and not credential.invalidated
            and credential.expires_at > now + self.expiry_margin
        )

    def authorize(self) -> AgentResponse:
        """Return a cache-only admission decision and schedule any due work."""
        now = self.clock()
        with self._lock:
            self._last_use_at = now
            credential = self._credential
            if not self._usable(credential, now):
                self._wake.set()
                return AgentResponse(
                    503,
                    {},
                    b'{"error":"platform_auth_unavailable"}',
                )
            due = (
                self._last_validation_attempt_at is None
                or now - self._last_validation_attempt_at >= self.validation_interval
            )
            if due:
                self._wake.set()
            token = credential.token
        return AgentResponse(
            200,
            {"Authorization": f"Bearer {token}"},
            b'{"status":"authorized"}',
        )

    def _failure(self, label: str, now: float, component: str) -> None:
        if label not in self._KNOWN_REASONS:
            label = "invalid_response"
        with self._lock:
            if component == "validate":
                self._validation_reason = label
            else:
                self._refresh_reason = label
            self._reason = self._validation_reason or self._refresh_reason
            self._failure_counters[label] = min(
                self._failure_counters.get(label, 0) + 1, 2_147_483_647
            )
            if component != "validate":
                delay = min(
                    self.retry_initial * (2 ** min(self._retry_count, 10)),
                    self.retry_max,
                )
                jitter = 0.75 + (0.5 * min(max(self.random_source(), 0.0), 1.0))
                self._next_retry_at = now + delay * jitter
                self._retry_count += 1

    @staticmethod
    def _json(response: HTTPResponse):
        content_type = response.headers.get("content-type", "")
        if content_type.split(";", 1)[0].strip().lower() != "application/json":
            raise _CandidateFailure("invalid_content_type")
        try:
            return json.loads(response.body)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise _CandidateFailure("invalid_json") from None

    @staticmethod
    def _decode_segment(value: str):
        try:
            padding = "=" * (-len(value) % 4)
            raw = base64.urlsafe_b64decode((value + padding).encode("ascii"))
            return json.loads(raw)
        except (ValueError, UnicodeError, json.JSONDecodeError):
            raise _CandidateFailure("invalid_jwt") from None

    def _inspect_jwt(self, token: str, now: float) -> float:
        if len(token.encode("utf-8")) > self.max_response_bytes:
            raise _CandidateFailure("invalid_jwt")
        parts = token.split(".")
        if len(parts) != 3 or not all(parts):
            raise _CandidateFailure("invalid_jwt")
        header = self._decode_segment(parts[0])
        claims = self._decode_segment(parts[1])
        if not isinstance(header, dict) or not isinstance(claims, dict):
            raise _CandidateFailure("invalid_jwt")
        if header.get("typ") != "JWT" or header.get("alg") != "HS256":
            raise _CandidateFailure("invalid_jwt")
        if claims.get("sub") != self.subject or claims.get("scope") != "data":
            raise _CandidateFailure("invalid_jwt")
        expiry = claims.get("exp")
        if isinstance(expiry, bool) or not isinstance(expiry, (int, float)):
            raise _CandidateFailure("invalid_jwt")
        if not math.isfinite(expiry):
            raise _CandidateFailure("invalid_jwt")
        if expiry <= now + self.expiry_margin:
            raise _CandidateFailure("invalid_jwt")
        if expiry > now + self.max_token_lifetime:
            raise _CandidateFailure("invalid_jwt")
        return float(expiry)

    def _read_admin_token(self) -> str:
        try:
            with self.admin_token_file.open("rb") as token_file:
                raw = token_file.read(4097)
        except OSError:
            raise _CandidateFailure("bootstrap_unavailable") from None
        if len(raw) > 4096:
            raise _CandidateFailure("bootstrap_unavailable")
        try:
            token = raw.decode("utf-8").strip()
        except UnicodeDecodeError:
            raise _CandidateFailure("bootstrap_unavailable") from None
        if not token:
            raise _CandidateFailure("bootstrap_unavailable")
        return token

    def _request(self, method: str, path: str, *, headers=None, body=None, max_body_bytes=None):
        return self.transport.request(
            method,
            self.upstream_url + path,
            headers=headers or {},
            body=body,
            timeout=self.request_timeout,
            max_body_bytes=max_body_bytes or self.max_response_bytes,
        )

    @staticmethod
    def _status_failure(prefix: str, status: int) -> _CandidateFailure:
        group = "5xx" if status >= 500 else "4xx"
        return _CandidateFailure(f"{prefix}_{group}")

    def _issue_and_validate(self, now: float) -> None:
        admin_token = self._read_admin_token()
        payload = json.dumps(
            {"email": self.subject, "api_token": admin_token},
            separators=(",", ":"),
        ).encode("utf-8")
        response = self._request(
            "POST",
            "/token",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            body=payload,
        )
        if response.status != 200:
            raise self._status_failure("issuer", response.status)
        document = self._json(response)
        if not isinstance(document, dict) or set(document) != {
            "email",
            "access_token",
            "token_type",
        }:
            raise _CandidateFailure("invalid_issuer_response")
        if document.get("email") != self.subject or document.get("token_type") != "bearer":
            raise _CandidateFailure("invalid_issuer_response")
        token = document.get("access_token")
        if not isinstance(token, str) or not token:
            raise _CandidateFailure("invalid_issuer_response")
        expires_at = self._inspect_jwt(token, now)

        validation = self._request(
            "GET",
            "/schema",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            max_body_bytes=self.max_schema_response_bytes,
        )
        if validation.status != 200:
            if validation.status == 401:
                raise _CandidateFailure("validation_401")
            raise self._status_failure("validation", validation.status)
        schema = self._json(validation)
        if not isinstance(schema, dict):
            raise _CandidateFailure("invalid_issuer_response")

        lifetime = expires_at - now
        renewal_fraction = 0.45 + 0.10 * min(max(self.random_source(), 0.0), 1.0)
        renew_at = now + lifetime * renewal_fraction
        with self._lock:
            self._generation += 1
            self._credential = _Credential(
                token=token,
                expires_at=expires_at,
                renew_at=renew_at,
                generation=self._generation,
                last_validated_at=now,
            )
            self._last_refresh_success_at = now
            self._last_validation_success_at = now
            self._last_validation_attempt_at = now
            self._next_retry_at = 0.0
            self._retry_count = 0
            self._reason = None
            self._refresh_reason = None
            self._validation_reason = None

    def _validate_generation(self, credential: _Credential, now: float) -> None:
        with self._lock:
            self._last_validation_attempt_at = now
        response = self._request(
            "GET",
            "/schema",
            headers={
                "Authorization": f"Bearer {credential.token}",
                "Accept": "application/json",
            },
            max_body_bytes=self.max_schema_response_bytes,
        )
        if response.status == 200:
            schema = self._json(response)
            if not isinstance(schema, dict):
                raise _CandidateFailure("invalid_issuer_response")
        self._apply_validation_status(credential.generation, response.status, now)

    def _apply_validation_status(self, generation: int, status: int, now: float) -> None:
        """Apply a validation result only if its credential generation is current."""
        with self._lock:
            credential = self._credential
            if credential is None or credential.generation != generation:
                return
            if status == 200:
                self._credential = _Credential(
                    token=credential.token,
                    expires_at=credential.expires_at,
                    renew_at=credential.renew_at,
                    generation=credential.generation,
                    last_validated_at=now,
                    invalidated=False,
                )
                self._last_validation_success_at = now
                self._validation_reason = None
                self._reason = self._refresh_reason
                return
            if status == 401:
                self._credential = _Credential(
                    token=credential.token,
                    expires_at=credential.expires_at,
                    renew_at=credential.renew_at,
                    generation=credential.generation,
                    last_validated_at=credential.last_validated_at,
                    invalidated=True,
                )
                self._validation_reason = "validation_401"
                self._reason = "validation_401"
                self._failure_counters["validation_401"] = min(
                    self._failure_counters.get("validation_401", 0) + 1,
                    2_147_483_647,
                )
                self._next_retry_at = now
                self._retry_count = 0
                self._wake.set()
                return
        label = "validation_5xx" if status >= 500 else "validation_4xx"
        self._failure(label, now, "validate")

    def _select_work(self, now: float):
        with self._lock:
            credential = self._credential
            if not self._usable(credential, now):
                return ("issue", None) if now >= self._next_retry_at else (None, None)
            recently_used = (
                self._last_use_at is not None and now - self._last_use_at <= self.active_window
            )
            validation_due = (
                self._last_validation_attempt_at is None
                or now - self._last_validation_attempt_at >= self.validation_interval
            )
            if recently_used and validation_due:
                return "validate", credential
            if now >= credential.renew_at and now >= self._next_retry_at:
                return "issue", None
            return None, None

    def process_once(self) -> bool:
        """Run at most one due lifecycle operation; useful for deterministic tests."""
        if not self._operation_lock.acquire(blocking=False):
            return False
        try:
            now = self.clock()
            action, credential = self._select_work(now)
            if action is None:
                return False
            try:
                if action == "issue":
                    self._issue_and_validate(now)
                else:
                    self._validate_generation(credential, now)
            except TransportFailure as error:
                self._failure(error.label, now, action)
            except _CandidateFailure as error:
                self._failure(error.label, now, action)
            return True
        finally:
            self._operation_lock.release()

    def _worker_loop(self) -> None:
        while not self._stop.is_set():
            self._wake.clear()
            if self.process_once():
                continue
            self._wake.wait(timeout=1.0)

    def start(self) -> None:
        if self._worker is not None:
            return
        self._worker = threading.Thread(
            target=self._worker_loop,
            name="credential-agent-worker",
            daemon=True,
        )
        self._worker.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._worker is not None:
            self._worker.join(timeout=max(2.0, self.request_timeout + 1.0))

    def health_snapshot(self) -> dict[str, object]:
        now = self.clock()
        with self._lock:
            credential = self._credential
            usable = self._usable(credential, now)
            return {
                "live": True,
                "ready": usable,
                "degraded": self._reason is not None,
                "refresh_degraded": self._refresh_reason is not None,
                "validation_degraded": self._validation_reason is not None,
                "reason": self._reason,
                "generation": credential.generation if credential else 0,
                "last_refresh_success_at": self._last_refresh_success_at,
                "last_validation_success_at": self._last_validation_success_at,
                "seconds_until_usable_expiry": max(
                    0.0,
                    credential.expires_at - self.expiry_margin - now if credential else 0.0,
                ),
                "failure_counters": dict(self._failure_counters),
            }

    def monitor_response(self, path: str) -> AgentResponse:
        health = self.health_snapshot()
        if path == "/livez":
            return AgentResponse(200, {}, b'{"status":"live"}')
        if path == "/readyz":
            status = 200 if health["ready"] else 503
            body = b'{"ready":true}' if status == 200 else b'{"ready":false}'
            return AgentResponse(status, {}, body)
        if path == "/metrics":
            lines = [
                "# HELP crawl4ai_credential_ready Whether a usable validated credential is cached.",
                "# TYPE crawl4ai_credential_ready gauge",
                f"crawl4ai_credential_ready {1 if health['ready'] else 0}",
                "# HELP crawl4ai_credential_degraded Whether renewal or validation is degraded.",
                "# TYPE crawl4ai_credential_degraded gauge",
                f"crawl4ai_credential_degraded {1 if health['degraded'] else 0}",
                "# HELP crawl4ai_credential_refresh_degraded Whether automatic issuance or renewal is degraded.",
                "# TYPE crawl4ai_credential_refresh_degraded gauge",
                f"crawl4ai_credential_refresh_degraded {1 if health['refresh_degraded'] else 0}",
                "# HELP crawl4ai_credential_validation_degraded Whether background validation is degraded.",
                "# TYPE crawl4ai_credential_validation_degraded gauge",
                f"crawl4ai_credential_validation_degraded {1 if health['validation_degraded'] else 0}",
                "# HELP crawl4ai_credential_seconds_until_usable_expiry Seconds before the cached credential reaches its expiry margin.",
                "# TYPE crawl4ai_credential_seconds_until_usable_expiry gauge",
                f"crawl4ai_credential_seconds_until_usable_expiry {health['seconds_until_usable_expiry']:.3f}",
                "# HELP crawl4ai_credential_last_refresh_success_seconds Unix timestamp of the last successful issuance and validation.",
                "# TYPE crawl4ai_credential_last_refresh_success_seconds gauge",
                f"crawl4ai_credential_last_refresh_success_seconds {health['last_refresh_success_at'] or 0:.3f}",
                "# HELP crawl4ai_credential_last_validation_success_seconds Unix timestamp of the last successful backend validation.",
                "# TYPE crawl4ai_credential_last_validation_success_seconds gauge",
                f"crawl4ai_credential_last_validation_success_seconds {health['last_validation_success_at'] or 0:.3f}",
                "# HELP crawl4ai_credential_failures_total Credential lifecycle failures by fixed reason category.",
                "# TYPE crawl4ai_credential_failures_total counter",
            ]
            for reason, count in sorted(health["failure_counters"].items()):
                lines.append(
                    'crawl4ai_credential_failures_total{reason="' + reason + '"} ' + str(count)
                )
            return AgentResponse(
                200,
                {},
                ("\n".join(lines) + "\n").encode("ascii"),
                "text/plain; version=0.0.4",
            )
        return AgentResponse(404, {}, b'{"error":"not_found"}')


def _send(handler: BaseHTTPRequestHandler, response: AgentResponse) -> None:
    handler.send_response(response.status)
    handler.send_header("Content-Type", response.content_type)
    handler.send_header("Content-Length", str(len(response.body)))
    handler.send_header("Cache-Control", "no-store")
    for name, value in response.headers.items():
        handler.send_header(name, value)
    handler.end_headers()
    handler.wfile.write(response.body)


class BoundedHTTPServer(ThreadingHTTPServer):
    """Threaded HTTP server with fixed concurrency and absolute request deadlines."""

    daemon_threads = True
    request_queue_size = 16

    def __init__(
        self,
        address,
        handler,
        *,
        request_timeout: float = DEFAULT_INBOUND_REQUEST_TIMEOUT,
        max_workers: int = DEFAULT_INBOUND_WORKERS,
    ):
        if not math.isfinite(request_timeout) or request_timeout <= 0:
            raise ValueError("request timeout must be finite and positive")
        if isinstance(max_workers, bool) or not isinstance(max_workers, int) or max_workers <= 0:
            raise ValueError("max workers must be a positive integer")
        self.request_timeout = request_timeout
        self._request_slots = threading.BoundedSemaphore(max_workers)
        self._active_lock = threading.Lock()
        self._active_requests: dict[socket.socket, float] = {}
        self._peak_requests = 0
        self._watchdog_stop = threading.Event()
        super().__init__(address, handler)
        self._watchdog = threading.Thread(
            target=self._watch_request_deadlines,
            name="credential-agent-http-watchdog",
            daemon=True,
        )
        self._watchdog.start()

    def process_request(self, request, client_address):
        self._request_slots.acquire()
        request.settimeout(self.request_timeout)
        with self._active_lock:
            self._active_requests[request] = time.monotonic() + self.request_timeout
            self._peak_requests = max(self._peak_requests, len(self._active_requests))
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._release_request(request)
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._release_request(request)

    def _release_request(self, request) -> None:
        with self._active_lock:
            registered = self._active_requests.pop(request, None) is not None
        if registered:
            self._request_slots.release()

    def _watch_request_deadlines(self) -> None:
        interval = min(0.05, self.request_timeout / 4)
        while not self._watchdog_stop.wait(interval):
            now = time.monotonic()
            with self._active_lock:
                expired = [
                    request
                    for request, deadline in self._active_requests.items()
                    if now >= deadline
                ]
            for request in expired:
                try:
                    request.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def active_request_count(self) -> int:
        with self._active_lock:
            return len(self._active_requests)

    def peak_request_count(self) -> int:
        with self._active_lock:
            return self._peak_requests

    def server_close(self) -> None:
        self._watchdog_stop.set()
        with self._active_lock:
            active = list(self._active_requests)
        for request in active:
            try:
                request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        self._watchdog.join(timeout=self.request_timeout + 0.1)
        super().server_close()


def _handler(agent: CredentialAgent, *, monitoring: bool):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            return

        def handle_expect_100(self):
            self.close_connection = True
            _send(self, AgentResponse(417, {}, b'{"error":"request_body_not_allowed"}'))
            return False

        def _bodyless(self) -> bool:
            transfer_encoding = self.headers.get("Transfer-Encoding")
            content_length = self.headers.get("Content-Length")
            if transfer_encoding:
                self.close_connection = True
                _send(self, AgentResponse(400, {}, b'{"error":"request_body_not_allowed"}'))
                return False
            if content_length is None:
                return True
            try:
                length = int(content_length)
            except ValueError:
                length = -1
            if length != 0:
                self.close_connection = True
                _send(self, AgentResponse(400, {}, b'{"error":"request_body_not_allowed"}'))
                return False
            return True

        def do_GET(self):
            if not self._bodyless():
                return
            if monitoring:
                _send(self, agent.monitor_response(self.path))
            else:
                _send(self, AgentResponse(404, {}, b'{"error":"not_found"}'))

        def do_POST(self):
            if not self._bodyless():
                return
            if monitoring or self.path != "/authorize":
                self.close_connection = True
                _send(self, AgentResponse(404, {}, b'{"error":"not_found"}'))
                return
            _send(self, agent.authorize())

    return Handler


def make_auth_server(
    address,
    agent: CredentialAgent,
    *,
    request_timeout: float = DEFAULT_INBOUND_REQUEST_TIMEOUT,
    max_workers: int = DEFAULT_INBOUND_WORKERS,
) -> BoundedHTTPServer:
    return BoundedHTTPServer(
        address,
        _handler(agent, monitoring=False),
        request_timeout=request_timeout,
        max_workers=max_workers,
    )


def make_monitor_server(
    address,
    agent: CredentialAgent,
    *,
    request_timeout: float = DEFAULT_INBOUND_REQUEST_TIMEOUT,
    max_workers: int = DEFAULT_INBOUND_WORKERS,
) -> BoundedHTTPServer:
    return BoundedHTTPServer(
        address,
        _handler(agent, monitoring=True),
        request_timeout=request_timeout,
        max_workers=max_workers,
    )


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream-url", default=DEFAULT_UPSTREAM_URL)
    parser.add_argument("--admin-token-file", type=Path, required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--auth-host", default=DEFAULT_AUTH_HOST)
    parser.add_argument("--auth-port", type=int, default=DEFAULT_AUTH_PORT)
    parser.add_argument("--monitor-host", default=DEFAULT_MONITOR_HOST)
    parser.add_argument("--monitor-port", type=int, default=DEFAULT_MONITOR_PORT)
    parser.add_argument("--request-timeout", type=float, default=5.0)
    parser.add_argument("--max-response-bytes", type=int, default=64 * 1024)
    parser.add_argument("--max-schema-response-bytes", type=int, default=2 * 1024 * 1024)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    agent = CredentialAgent(
        upstream_url=args.upstream_url,
        admin_token_file=args.admin_token_file,
        subject=args.subject,
        request_timeout=args.request_timeout,
        max_response_bytes=args.max_response_bytes,
        max_schema_response_bytes=args.max_schema_response_bytes,
    )
    auth_server = make_auth_server((args.auth_host, args.auth_port), agent)
    monitor_server = make_monitor_server((args.monitor_host, args.monitor_port), agent)
    monitor_thread = threading.Thread(
        target=monitor_server.serve_forever,
        name="credential-agent-monitor",
        daemon=True,
    )
    agent.start()
    monitor_thread.start()
    try:
        auth_server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        auth_server.shutdown()
        auth_server.server_close()
        monitor_server.shutdown()
        monitor_server.server_close()
        monitor_thread.join(timeout=2)
        agent.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
