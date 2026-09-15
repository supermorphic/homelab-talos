import base64
import importlib.util
import json
import math
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "kubernetes/apps/web-research/crawl4ai/runtime/credential_agent.py"
SPEC = importlib.util.spec_from_file_location("crawl4ai_credential_agent", MODULE_PATH)
credential_agent = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = credential_agent
SPEC.loader.exec_module(credential_agent)


def _segment(value):
    raw = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def make_jwt(subject, expiry, *, algorithm="HS256", token_type="JWT", scope="data"):
    return ".".join(
        (
            _segment({"alg": algorithm, "typ": token_type}),
            _segment({"sub": subject, "scope": scope, "exp": expiry}),
            _segment("synthetic-signature"),
        )
    )


class FakeClock:
    def __init__(self, value=1_800_000_000.0):
        self.value = value

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


class ScriptedTransport:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def request(self, method, url, *, headers, body, timeout, max_body_bytes):
        self.calls.append(
            {
                "method": method,
                "url": url,
                "headers": dict(headers),
                "body": body,
                "timeout": timeout,
                "max_body_bytes": max_body_bytes,
            }
        )
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def json_response(status, value, content_type="application/json"):
    return credential_agent.HTTPResponse(
        status=status,
        headers={"content-type": content_type},
        body=json.dumps(value, separators=(",", ":")).encode(),
    )


class AgentCase(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.token_file = Path(self.tempdir.name) / "admin-token"
        self.token_file.write_text("admin-one\n", encoding="utf-8")
        self.clock = FakeClock()
        self.subject = "crawler@example.com"

    def token_response(self, token):
        return json_response(
            200,
            {"email": self.subject, "access_token": token, "token_type": "bearer"},
        )

    def agent(self, responses, **overrides):
        transport = ScriptedTransport(responses)
        options = {
            "upstream_url": "http://127.0.0.1:11235",
            "admin_token_file": self.token_file,
            "subject": self.subject,
            "transport": transport,
            "clock": self.clock,
            "random_source": lambda: 0.5,
            "request_timeout": 0.25,
            "max_response_bytes": 1024,
            "expiry_margin": 10,
            "validation_interval": 60,
            "active_window": 300,
            "retry_initial": 2,
            "retry_max": 30,
            "max_token_lifetime": 7200,
        }
        options.update(overrides)
        return credential_agent.CredentialAgent(**options), transport

    def mint(self, lifetime=3600):
        return make_jwt(self.subject, int(self.clock() + lifetime))


class CredentialLifecycleTests(AgentCase):
    def test_timing_configuration_must_be_finite(self):
        for name in (
            "request_timeout",
            "expiry_margin",
            "validation_interval",
            "active_window",
            "retry_initial",
            "retry_max",
            "max_token_lifetime",
        ):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.agent([], **{name: math.nan})

    def test_upstream_issuer_must_be_an_http_loopback_origin(self):
        for url in (
            "https://127.0.0.1:11235",
            "http://192.0.2.10:11235",
            "http://user:password@127.0.0.1:11235",
            "http://127.0.0.1:11235/base",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.agent([], upstream_url=url)

    def test_background_worker_bootstraps_automatically(self):
        token = self.mint()
        agent, _ = self.agent(
            [self.token_response(token), json_response(200, {"openapi": "3.1.0"})]
        )
        self.addCleanup(agent.stop)

        agent.start()

        deadline = time.monotonic() + 1
        while agent.authorize().status != 200 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(200, agent.authorize().status)

    def test_startup_mints_validates_and_admits_from_cache(self):
        token = self.mint()
        agent, transport = self.agent(
            [self.token_response(token), json_response(200, {"openapi": "3.1.0"})]
        )

        self.assertTrue(agent.process_once())
        decision = agent.authorize()

        self.assertEqual(200, decision.status)
        self.assertEqual(f"Bearer {token}", decision.headers["Authorization"])
        self.assertNotIn(token, decision.body.decode())
        self.assertEqual(2, len(transport.calls))
        issue_body = json.loads(transport.calls[0]["body"])
        self.assertEqual({"email": self.subject, "api_token": "admin-one"}, issue_body)
        self.assertEqual("GET", transport.calls[1]["method"])
        self.assertEqual("/schema", urllib.parse.urlsplit(transport.calls[1]["url"]).path)
        self.assertEqual(f"Bearer {token}", transport.calls[1]["headers"]["Authorization"])

    def test_admission_never_waits_for_due_validation_and_burst_is_singleflight(self):
        token = self.mint()
        agent, transport = self.agent(
            [
                self.token_response(token),
                json_response(200, {}),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        self.clock.advance(61)

        first = agent.authorize()
        second = agent.authorize()

        self.assertEqual(200, first.status)
        self.assertEqual(200, second.status)
        self.assertEqual(2, len(transport.calls))
        self.assertTrue(agent.process_once())
        self.assertFalse(agent.process_once())
        self.assertEqual(3, len(transport.calls))

    def test_proactive_renewal_reads_replaced_admin_token_file(self):
        first = self.mint()
        second = make_jwt(self.subject, int(self.clock() + 5401))
        agent, transport = self.agent(
            [
                self.token_response(first),
                json_response(200, {}),
                self.token_response(second),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        self.token_file.write_text("admin-two\n", encoding="utf-8")
        self.clock.advance(1801)

        self.assertTrue(agent.process_once())

        self.assertEqual(f"Bearer {second}", agent.authorize().headers["Authorization"])
        self.assertEqual("admin-two", json.loads(transport.calls[2]["body"])["api_token"])

    def test_concurrent_workers_cannot_duplicate_issuance(self):
        token = self.mint()
        entered = threading.Event()
        release = threading.Event()
        responses = [self.token_response(token), json_response(200, {})]

        class BlockingTransport(ScriptedTransport):
            def request(inner_self, *args, **kwargs):
                if not inner_self.calls:
                    entered.set()
                    release.wait(timeout=1)
                return super().request(*args, **kwargs)

        transport = BlockingTransport(responses)
        agent, _ = self.agent([])
        agent.transport = transport
        result = []
        thread = threading.Thread(target=lambda: result.append(agent.process_once()))
        thread.start()
        self.addCleanup(thread.join, 1)
        self.assertTrue(entered.wait(timeout=1))

        duplicate = agent.process_once()
        release.set()
        thread.join(timeout=1)

        self.assertFalse(duplicate)
        self.assertEqual([True], result)
        self.assertEqual(2, len(transport.calls))

    def test_expired_cache_fails_closed_then_recovers_automatically(self):
        expiring = self.mint(lifetime=30)
        replacement = make_jwt(self.subject, int(self.clock() + 3600))
        agent, _ = self.agent(
            [
                self.token_response(expiring),
                json_response(200, {}),
                self.token_response(replacement),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        self.clock.advance(21)

        denied = agent.authorize()
        self.assertEqual(503, denied.status)
        self.assertEqual({"error": "platform_auth_unavailable"}, json.loads(denied.body))

        self.assertTrue(agent.process_once())
        self.assertEqual(200, agent.authorize().status)

    def test_confirmed_401_invalidates_but_ambiguous_failures_keep_usable_cache(self):
        for failure in (
            json_response(503, {"detail": "internal secret must not escape"}),
            credential_agent.TransportFailure("timeout"),
        ):
            with self.subTest(failure=type(failure).__name__):
                token = self.mint()
                agent, _ = self.agent(
                    [self.token_response(token), json_response(200, {}), failure]
                )
                agent.process_once()
                self.clock.advance(61)
                agent.authorize()
                agent.process_once()

                self.assertEqual(200, agent.authorize().status)
                health = agent.health_snapshot()
                self.assertTrue(health["degraded"])
                self.assertIn(health["reason"], {"validation_5xx", "timeout"})

        token = self.mint()
        replacement = make_jwt(self.subject, int(self.clock() + 3700))
        agent, _ = self.agent(
            [
                self.token_response(token),
                json_response(200, {}),
                json_response(401, {"detail": "no"}),
                self.token_response(replacement),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        self.clock.advance(61)
        agent.authorize()
        agent.process_once()
        self.assertEqual(503, agent.authorize().status)
        agent.process_once()
        self.assertEqual(f"Bearer {replacement}", agent.authorize().headers["Authorization"])

    def test_refresh_failure_is_not_hidden_by_a_validation_success(self):
        token = self.mint()
        agent, _ = self.agent(
            [
                self.token_response(token),
                json_response(200, {}),
                credential_agent.TransportFailure("timeout"),
            ]
        )
        agent.process_once()
        generation = agent.health_snapshot()["generation"]
        self.clock.advance(1801)
        agent.process_once()
        self.assertTrue(agent.health_snapshot()["refresh_degraded"])

        agent._apply_validation_status(generation, 200, self.clock())

        health = agent.health_snapshot()
        self.assertTrue(health["degraded"])
        self.assertTrue(health["refresh_degraded"])
        self.assertFalse(health["validation_degraded"])

    def test_failed_renewal_cannot_starve_active_validation_or_401_recovery(self):
        token = self.mint()
        replacement = make_jwt(self.subject, int(self.clock() + 5600))
        agent, transport = self.agent(
            [
                self.token_response(token),
                json_response(200, {}),
                credential_agent.TransportFailure("timeout"),
                json_response(401, {"detail": "invalid"}),
                self.token_response(replacement),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        self.clock.advance(1801)
        agent.process_once()
        self.assertTrue(agent.health_snapshot()["refresh_degraded"])
        self.clock.advance(61)
        self.assertEqual(200, agent.authorize().status)

        agent.process_once()

        self.assertEqual("GET", transport.calls[3]["method"])
        self.assertEqual("/schema", urllib.parse.urlsplit(transport.calls[3]["url"]).path)
        self.assertEqual(503, agent.authorize().status)
        self.assertTrue(agent.health_snapshot()["refresh_degraded"])
        self.assertTrue(agent.process_once())
        self.assertEqual("POST", transport.calls[4]["method"])
        self.assertEqual(f"Bearer {replacement}", agent.authorize().headers["Authorization"])

    def test_validation_failure_does_not_back_off_due_renewal(self):
        token = self.mint()
        replacement = make_jwt(self.subject, int(self.clock() + 5600))
        agent, transport = self.agent(
            [
                self.token_response(token),
                json_response(200, {}),
                json_response(503, {"detail": "unavailable"}),
                self.token_response(replacement),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        self.clock.advance(1801)
        self.assertEqual(200, agent.authorize().status)

        self.assertTrue(agent.process_once())
        self.assertEqual("GET", transport.calls[2]["method"])
        self.assertTrue(agent.health_snapshot()["validation_degraded"])
        self.assertTrue(agent.process_once())
        self.assertEqual("POST", transport.calls[3]["method"])
        self.assertEqual(f"Bearer {replacement}", agent.authorize().headers["Authorization"])

    def test_late_401_for_old_generation_does_not_evict_replacement(self):
        first = self.mint()
        second = make_jwt(self.subject, int(self.clock() + 4000))
        agent, _ = self.agent(
            [
                self.token_response(first),
                json_response(200, {}),
                self.token_response(second),
                json_response(200, {}),
            ]
        )
        agent.process_once()
        old_generation = agent.health_snapshot()["generation"]
        self.clock.advance(1801)
        agent.process_once()

        agent._apply_validation_status(old_generation, 401, self.clock())

        self.assertEqual(f"Bearer {second}", agent.authorize().headers["Authorization"])

    def test_malformed_candidates_never_enter_cache(self):
        valid = self.mint()
        cases = {
            "content_type": credential_agent.HTTPResponse(
                200, {"content-type": "text/plain"}, b"{}"
            ),
            "json": credential_agent.HTTPResponse(200, {"content-type": "application/json"}, b"{"),
            "email": json_response(
                200, {"email": "other@example.com", "access_token": valid, "token_type": "bearer"}
            ),
            "token_type": json_response(
                200, {"email": self.subject, "access_token": valid, "token_type": "admin"}
            ),
            "algorithm": self.token_response(
                make_jwt(self.subject, int(self.clock() + 3600), algorithm="none")
            ),
            "jwt_type": self.token_response(
                make_jwt(self.subject, int(self.clock() + 3600), token_type="JOSE")
            ),
            "subject": self.token_response(
                make_jwt("other@example.com", int(self.clock() + 3600))
            ),
            "scope": self.token_response(
                make_jwt(self.subject, int(self.clock() + 3600), scope="admin")
            ),
            "expiry": self.token_response(make_jwt(self.subject, int(self.clock() + 9000))),
        }
        for name, response in cases.items():
            with self.subTest(name=name):
                agent, _ = self.agent([response])
                agent.process_once()
                self.assertEqual(503, agent.authorize().status)
                self.assertTrue(
                    agent.health_snapshot()["reason"]
                    in {
                        "invalid_content_type",
                        "invalid_json",
                        "invalid_issuer_response",
                        "invalid_jwt",
                    }
                )

    def test_nonfinite_expiry_and_extra_issuer_fields_are_rejected(self):
        for name, response in (
            (
                "nonfinite_expiry",
                self.token_response(make_jwt(self.subject, math.nan)),
            ),
            (
                "extra_field",
                json_response(
                    200,
                    {
                        "email": self.subject,
                        "access_token": self.mint(),
                        "token_type": "bearer",
                        "unexpected": "field",
                    },
                ),
            ),
        ):
            with self.subTest(name=name):
                agent, _ = self.agent([response, json_response(200, {})])
                agent.process_once()
                self.assertEqual(503, agent.authorize().status)
                self.assertEqual(0, agent.health_snapshot()["generation"])

    def test_malformed_renewal_preserves_the_usable_generation(self):
        token = self.mint()
        malformed = json_response(
            200,
            {
                "email": self.subject,
                "access_token": make_jwt(self.subject, math.nan),
                "token_type": "bearer",
            },
        )
        agent, _ = self.agent(
            [
                self.token_response(token),
                json_response(200, {}),
                malformed,
                json_response(200, {}),
            ]
        )
        agent.process_once()
        generation = agent.health_snapshot()["generation"]
        self.clock.advance(1801)

        agent.process_once()

        self.assertEqual(generation, agent.health_snapshot()["generation"])
        self.assertEqual(f"Bearer {token}", agent.authorize().headers["Authorization"])
        self.assertTrue(agent.health_snapshot()["refresh_degraded"])


class FakeIssuer:
    def __init__(self, subject, clock, *, oversized=False):
        self.subject = subject
        self.clock = clock
        self.oversized = oversized
        self.requests = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                owner.requests.append(("POST", self.path, dict(self.headers), body))
                if owner.oversized:
                    payload = b"x" * 2048
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                request = json.loads(body)
                token = make_jwt(owner.subject, int(owner.clock() + 3600))
                payload = json.dumps(
                    {"email": request["email"], "access_token": token, "token_type": "bearer"}
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_GET(self):
                owner.requests.append(("GET", self.path, dict(self.headers), b""))
                payload = b'{"openapi":"3.1.0"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class RealHttpAndSurfaceTests(AgentCase):
    def test_real_local_issuer_bootstrap_uses_bounded_transport(self):
        issuer = FakeIssuer(self.subject, self.clock)
        self.addCleanup(issuer.close)
        agent = credential_agent.CredentialAgent(
            upstream_url=issuer.url,
            admin_token_file=self.token_file,
            subject=self.subject,
            clock=self.clock,
            random_source=lambda: 0.5,
            request_timeout=1,
            max_response_bytes=1024,
            expiry_margin=10,
        )

        self.assertTrue(agent.process_once())
        self.assertEqual(200, agent.authorize().status)
        self.assertEqual(["/token", "/schema"], [request[1] for request in issuer.requests])

    def test_transport_rejects_oversized_body_and_redirects(self):
        issuer = FakeIssuer(self.subject, self.clock, oversized=True)
        self.addCleanup(issuer.close)
        transport = credential_agent.UrllibTransport()
        with self.assertRaisesRegex(credential_agent.TransportFailure, "response_too_large"):
            transport.request(
                "POST", issuer.url + "/token", headers={}, body=b"{}", timeout=1, max_body_bytes=64
            )

        destination_hits = []

        class RedirectHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/credential")
                    self.end_headers()
                else:
                    destination_hits.append(self.path)
                    self.send_response(200)
                    self.end_headers()

        server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with self.assertRaisesRegex(credential_agent.TransportFailure, "redirect"):
            transport.request(
                "GET",
                f"http://127.0.0.1:{server.server_port}/redirect",
                headers={},
                body=None,
                timeout=1,
                max_body_bytes=64,
            )
        self.assertEqual([], destination_hits)

    def test_transport_enforces_one_total_deadline_for_a_slow_body(self):
        class SlowHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "5")
                self.end_headers()
                for byte in b"[0,0]":
                    try:
                        self.wfile.write(bytes([byte]))
                        self.wfile.flush()
                    except BrokenPipeError:
                        return
                    time.sleep(0.08)

        server = ThreadingHTTPServer(("127.0.0.1", 0), SlowHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        started = time.monotonic()

        with self.assertRaisesRegex(credential_agent.TransportFailure, "timeout"):
            credential_agent.UrllibTransport().request(
                "GET",
                f"http://127.0.0.1:{server.server_port}/slow",
                headers={},
                body=None,
                timeout=0.15,
                max_body_bytes=64,
            )

        self.assertLess(time.monotonic() - started, 0.3)

    def test_transport_maps_incomplete_http_response_to_bounded_reason(self):
        class DisconnectHandler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def handle(self):
                self.connection.close()

        server = ThreadingHTTPServer(("127.0.0.1", 0), DisconnectHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

        with self.assertRaisesRegex(credential_agent.TransportFailure, "network_error"):
            credential_agent.UrllibTransport().request(
                "GET",
                f"http://127.0.0.1:{server.server_port}/disconnect",
                headers={},
                body=None,
                timeout=0.5,
                max_body_bytes=64,
            )

    def test_auth_and_monitor_http_surfaces_are_token_free_except_backend_header(self):
        token = self.mint()
        agent, _ = self.agent([self.token_response(token), json_response(200, {})])
        agent.process_once()
        auth_server = credential_agent.make_auth_server(("127.0.0.1", 0), agent)
        monitor_server = credential_agent.make_monitor_server(("127.0.0.1", 0), agent)
        threads = []
        for server in (auth_server, monitor_server):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)
            self.addCleanup(thread.join, 2)
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)

        request = urllib.request.Request(
            f"http://127.0.0.1:{auth_server.server_port}/authorize",
            method="POST",
            headers={"Authorization": "Bearer consumer-secret"},
        )
        with urllib.request.urlopen(request, timeout=1) as response:
            self.assertEqual(f"Bearer {token}", response.headers["Authorization"])
            self.assertNotIn(token, response.read().decode())

        for path in ("/livez", "/readyz", "/metrics"):
            with urllib.request.urlopen(
                f"http://127.0.0.1:{monitor_server.server_port}{path}", timeout=1
            ) as response:
                payload = response.read().decode()
                self.assertNotIn(token, payload)
                self.assertNotIn("consumer-secret", payload)
                if path == "/metrics":
                    self.assertIn("crawl4ai_credential_last_refresh_success_seconds", payload)
                    self.assertIn("crawl4ai_credential_last_validation_success_seconds", payload)

        with self.assertRaises(urllib.error.HTTPError) as missing:
            urllib.request.urlopen(
                urllib.request.Request(
                    f"http://127.0.0.1:{auth_server.server_port}/not-authorize",
                    method="POST",
                    data=b"",
                ),
                timeout=1,
            )
        self.assertEqual(404, missing.exception.code)
        self.assertNotIn(token, missing.exception.read().decode())

    def test_auth_rejects_request_bodies_without_reading_or_returning_a_token(self):
        token = self.mint()
        agent, _ = self.agent([self.token_response(token), json_response(200, {})])
        agent.process_once()
        server = credential_agent.make_auth_server(("127.0.0.1", 0), agent)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        client = socket.create_connection(("127.0.0.1", server.server_port), timeout=1)
        self.addCleanup(client.close)

        client.sendall(
            b"POST /authorize HTTP/1.1\r\nHost: localhost\r\n"
            b"Content-Length: 100\r\nConnection: close\r\n\r\n"
        )
        response = client.recv(4096)

        self.assertIn(b" 400 ", response)
        self.assertNotIn(token.encode(), response)

    def test_slow_incomplete_headers_are_bounded_and_server_recovers(self):
        token = self.mint()
        agent, _ = self.agent([self.token_response(token), json_response(200, {})])
        agent.process_once()
        server = credential_agent.make_auth_server(
            ("127.0.0.1", 0), agent, request_timeout=0.15, max_workers=2
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        stalled = [
            socket.create_connection(("127.0.0.1", server.server_port), timeout=1)
            for _ in range(2)
        ]
        for client in stalled:
            self.addCleanup(client.close)
            client.sendall(b"POST /authorize HTTP/1.1\r\nHost: local")
        deadline = time.monotonic() + 1
        while server.active_request_count() < 2 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(2, server.active_request_count())

        request = urllib.request.Request(
            f"http://127.0.0.1:{server.server_port}/authorize", method="POST"
        )
        with urllib.request.urlopen(request, timeout=1) as response:
            self.assertEqual(f"Bearer {token}", response.headers["Authorization"])
        self.assertLessEqual(server.peak_request_count(), 2)
        for client in stalled:
            client.settimeout(0.5)
            stalled_response = client.recv(4096)
            self.assertNotIn(token.encode(), stalled_response)

    def test_readiness_tracks_usable_access_while_liveness_does_not(self):
        token = self.mint(lifetime=30)
        agent, _ = self.agent([self.token_response(token), json_response(200, {})])
        agent.process_once()
        ready = agent.monitor_response("/readyz")
        self.assertEqual(200, ready.status)
        self.assertEqual({"ready": True}, json.loads(ready.body))
        self.clock.advance(21)
        unavailable = agent.monitor_response("/readyz")
        self.assertEqual(503, unavailable.status)
        self.assertEqual({"ready": False}, json.loads(unavailable.body))
        self.assertEqual(200, agent.monitor_response("/livez").status)

    def test_cli_defaults_and_configurable_auth_bind(self):
        defaults = credential_agent.parse_args(
            ["--admin-token-file", str(self.token_file), "--subject", self.subject]
        )
        self.assertEqual("http://127.0.0.1:11235", defaults.upstream_url)
        self.assertEqual("127.0.0.1", defaults.auth_host)
        self.assertEqual(9000, defaults.auth_port)
        self.assertEqual("0.0.0.0", defaults.monitor_host)
        self.assertEqual(9001, defaults.monitor_port)

        configured = credential_agent.parse_args(
            [
                "--admin-token-file",
                str(self.token_file),
                "--subject",
                self.subject,
                "--auth-host",
                "0.0.0.0",
                "--auth-port",
                "19000",
            ]
        )
        self.assertEqual("0.0.0.0", configured.auth_host)
        self.assertEqual(19000, configured.auth_port)


if __name__ == "__main__":
    unittest.main()
