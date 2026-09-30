import base64
import contextlib
import io
import json
import unittest
from unittest.mock import Mock, patch

from scripts.openbao import issuer


class IssuerTests(unittest.TestCase):
    def test_probe_claims_are_sanitized_and_require_nonexpiring_secret_bound_identity(self):
        claims = {"sub": "system:serviceaccount:openbao:openbao",
                  "kubernetes.io/serviceaccount/secret.name": "openbao-issuer-token-v1"}
        for changes, expected in (({}, True), ({"exp": 1000}, False),
                                  ({"sub": "wrong"}, False),
                                  ({"kubernetes.io/serviceaccount/secret.name": "other"}, False)):
            value = {**claims, **changes}
            token = "synthetic." + base64.urlsafe_b64encode(json.dumps(value).encode()).decode() + ".private"
            output = io.StringIO()
            with (patch("pathlib.Path.read_text", return_value=token),
                  patch("sys.argv", ["probe", "openbao-issuer-token-v1"]),
                  contextlib.redirect_stdout(output)):
                exec(compile(issuer.CLAIMS_PROBE, "<synthetic-probe>", "exec"), {})  # noqa: S102 -- Execute repository probe with synthetic credentials only.
            self.assertEqual(json.loads(output.getvalue()), {"stable_issuer": expected})
            self.assertNotIn(token, output.getvalue())

    def test_probe_uses_actual_api_identity_not_claims_alone(self):
        probe = Mock()
        probe.scope.assert_owned = Mock()
        probe.scope.command.return_value = b'{"stable_issuer":true}'
        probe.pod = {"metadata": {"name": "synthetic", "namespace": "openbao"}}
        probe.request.return_value = (201, {"status": {"userInfo": {
            "username": "system:serviceaccount:openbao:openbao"}}})
        issuer.verify_identity(probe)
        probe.request.return_value = (401, {})
        with self.assertRaises(issuer.issuance.AcceptanceError):
            issuer.verify_identity(probe)


if __name__ == "__main__":
    unittest.main()
