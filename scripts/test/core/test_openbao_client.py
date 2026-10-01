import io
import json
import ssl
import unittest
import urllib.error
from contextlib import nullcontext, redirect_stdout
from unittest.mock import patch

from scripts.openbao.client import AmbiguousWrite, BaoClient, MalformedResponse, ReadFailure


class Response:
    def __init__(self, body=b"{}", status=200, url="https://openbao.example/v1/sys/health"):
        self.body = io.BytesIO(body)
        self.status = status
        self.url = url
        self.headers = {"Content-Length": str(len(body))}

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def read(self, size=-1):
        return self.body.read(size)

    def geturl(self):
        return self.url


class ClientTest(unittest.TestCase):
    def test_delete_is_one_bounded_mutation_without_blind_retry(self):
        seen = []
        def open_request(request, timeout):
            seen.append(request.get_method())
            raise TimeoutError("SYNTHETIC_PRIVATE_MARKER")
        client = BaoClient("https://openbao.example", opener=open_request)
        with self.assertRaises(AmbiguousWrite) as caught:
            client.delete("auth/homelab-approle/role/synthetic-owned", token="synthetic-operator")
        self.assertNotIn("SYNTHETIC_PRIVATE_MARKER", str(caught.exception))
        self.assertEqual(seen, ["DELETE"])

    def test_verified_tls_and_bounded_read(self):
        seen = []

        def open_request(request, timeout):
            seen.append((request.get_method(), request.full_url, timeout))
            return Response(b'{"data":{"ready":true}}', url=request.full_url)

        client = BaoClient("https://openbao.example", opener=open_request)
        self.assertEqual(client.read("sys/health"), {"data": {"ready": True}})
        self.assertEqual(seen, [("GET", "https://openbao.example/v1/sys/health", 5)])
        self.assertEqual(client.ssl_context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(client.ssl_context.check_hostname)

    def test_tls_hostname_timeout_redirect_and_size_fail_closed(self):
        for error in (
            ssl.SSLCertVerificationError("synthetic-private-marker"),
            TimeoutError("synthetic-private-marker"),
        ):
            client = BaoClient(
                "https://openbao.example",
                opener=lambda *_, error=error, **__: (_ for _ in ()).throw(error),
            )
            with self.assertRaises(ReadFailure) as caught:
                client.read("sys/health")
            self.assertNotIn("synthetic-private-marker", str(caught.exception))
        client = BaoClient(
            "https://openbao.example",
            opener=lambda request, timeout: Response(url="https://other.example/v1/sys/health"),
        )
        with self.assertRaises(ReadFailure):
            client.read("sys/health")
        client = BaoClient(
            "https://openbao.example",
            max_bytes=16,
            opener=lambda request, timeout: Response(b"x" * 17, url=request.full_url),
        )
        with self.assertRaises(MalformedResponse):
            client.read("sys/health")

    def test_malformed_json_and_forbidden_are_classified(self):
        client = BaoClient(
            "https://openbao.example",
            opener=lambda request, timeout: Response(b"{", url=request.full_url),
        )
        with self.assertRaises(MalformedResponse):
            client.read("sys/health")
        malformed_length = Response(b"{}")
        malformed_length.headers["Content-Length"] = "synthetic-private-marker"
        client = BaoClient(
            "https://openbao.example", opener=lambda request, timeout: malformed_length
        )
        with self.assertRaises(MalformedResponse) as caught:
            client.read("sys/health")
        self.assertNotIn("synthetic-private-marker", str(caught.exception))
        client = BaoClient(
            "https://openbao.example",
            opener=lambda *_, **__: (_ for _ in ()).throw(
                urllib.error.HTTPError(
                    "https://openbao.example", 403, "synthetic-private-marker", {}, None
                )
            ),
        )
        with self.assertRaises(ReadFailure) as caught:
            client.read("sys/health")
        self.assertEqual(str(caught.exception), "read-denied")

    def test_empty_204_post_is_success_but_nonempty_malformed_is_refused(self):
        client = BaoClient(
            "https://openbao.example",
            opener=lambda request, timeout: Response(b"", status=204, url=request.full_url),
        )
        self.assertEqual(client.post("sys/auth/test", {}), {})
        client = BaoClient(
            "https://openbao.example",
            opener=lambda request, timeout: Response(b"{", status=204, url=request.full_url),
        )
        with self.assertRaises(MalformedResponse):
            client.post("sys/auth/test", {})

    def test_truncated_initialization_response_is_ambiguous(self):
        import http.client

        class Truncated(Response):
            def read(self, size=-1):
                raise http.client.IncompleteRead(b"synthetic-partial", 100)

        client = BaoClient(
            "https://openbao.example",
            opener=lambda request, timeout: Truncated(url=request.full_url),
        )
        with self.assertRaises(AmbiguousWrite):
            client.post("sys/init", {"recovery_shares": 1})

    def test_post_has_no_retry_after_ambiguous_failure(self):
        calls = []

        def fail(*_, **__):
            calls.append(1)
            raise TimeoutError("synthetic-private-marker")

        client = BaoClient("https://openbao.example", opener=fail)
        with self.assertRaises(AmbiguousWrite):
            client.post("sys/init", {"secret_shares": 1}, token="synthetic-token")
        self.assertEqual(len(calls), 1)

    def test_http_write_failure_retains_only_status_code(self):
        for status in (400, 403, 500):
            with self.subTest(status=status):
                client = BaoClient(
                    "https://openbao.example",
                    opener=lambda *_, status=status, **__: (_ for _ in ()).throw(
                        urllib.error.HTTPError(
                            "https://openbao.example/v1/auth/homelab-jwt/config",
                            status,
                            "synthetic-private-marker",
                            {},
                            None,
                        )
                    ),
                )
                with self.assertRaises(AmbiguousWrite) as caught:
                    client.post("auth/homelab-jwt/config", {"provider_config": {"provider": "kubernetes"}})
                self.assertEqual(caught.exception.http_status, status)
                self.assertEqual(str(caught.exception), "ambiguous-write")
                self.assertNotIn("synthetic-private-marker", str(caught.exception))

    def test_returned_http_write_failure_retains_only_status_code(self):
        for status in (307, 400, 500):
            with self.subTest(status=status):
                client = BaoClient(
                    "https://openbao.example",
                    opener=lambda request, timeout, status=status: Response(
                        b"synthetic-private-marker", status=status, url=request.full_url
                    ),
                )
                with self.assertRaises(AmbiguousWrite) as caught:
                    client.post("auth/homelab-jwt/config", {"provider_config": {"provider": "kubernetes"}})
                self.assertEqual(caught.exception.http_status, status)
                self.assertEqual(str(caught.exception), "ambiguous-write")
                self.assertNotIn("synthetic-private-marker", str(caught.exception))

    def test_operator_cli_reports_write_status_without_private_material(self):
        from scripts.openbao.operator import main

        failure = AmbiguousWrite("ambiguous-write")
        failure.http_status = 400
        output = io.StringIO()
        with (
            patch.dict(
                "os.environ",
                {
                    "OPENBAO_OPERATOR_KUBECONFIG": "/synthetic/kubeconfig",
                    "OPENBAO_CONFIG_CONFIRM": "synthetic-confirm",
                },
                clear=True,
            ),
            patch("scripts.openbao.operator.Path.is_file", return_value=True),
            patch("scripts.openbao.operator.guards.freeze_target"),
            patch("scripts.openbao.operator.OperatorClient"),
            patch("scripts.openbao.operator.private_prompt", return_value="synthetic-secret-token"),
            patch(
                "scripts.openbao.operator.apply.run",
                side_effect=[
                    {"confirmation": "synthetic-confirm", "changes": []},
                    failure,
                ],
            ),
            patch("scripts.openbao.operator.lease", return_value=nullcontext()),
            redirect_stdout(output),
        ):
            self.assertEqual(main(["operator", "config-apply"]), 1)
        self.assertEqual(
            json.loads(output.getvalue()),
            {"status": "incomplete", "classification": "ambiguous-write", "http_status": 400},
        )
        self.assertNotIn("synthetic-secret-token", output.getvalue())

    def test_slow_initialization_response_is_retainable_without_extending_other_writes(self):
        calls = []

        def open_request(request, timeout):
            calls.append((request.full_url, timeout))
            if timeout < 8:
                raise TimeoutError("synthetic-response-still-pending")
            return Response(
                b'{"root_token":"synthetic-root","recovery_keys_base64":["synthetic-share"]}',
                url=request.full_url,
            )

        client = BaoClient("https://openbao.example", opener=open_request)
        response = client.post("sys/init", {"recovery_shares": 1, "recovery_threshold": 1})
        self.assertEqual(response["root_token"], "synthetic-root")
        self.assertEqual(response["recovery_keys_base64"], ["synthetic-share"])
        with self.assertRaises(AmbiguousWrite):
            client.post("sys/policies/acl/synthetic", {"policy": "synthetic"})
        self.assertEqual(len(calls), 2)
        self.assertGreaterEqual(calls[0][1], 8)
        self.assertEqual(calls[1][1], 5)


if __name__ == "__main__":
    unittest.main()
