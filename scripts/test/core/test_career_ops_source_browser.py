"""Exercise the browser producer against a scripted DOM and HTTP boundary.

DOM parsing is a browser dependency; these fixtures represent server readback,
and distinguish submitted scope from the actual server-stored permission.
"""

import json
import subprocess
import unittest
from pathlib import Path


class BrowserProducerTest(unittest.TestCase):
    def run_producer(
        self,
        *,
        broad=False,
        signed_out=False,
        fail_post=False,
        resume_only=False,
        fail_probe=False,
        preparation=False,
    ):
        path = Path("scripts/repository/career_ops_source_browser.js")
        self.assertTrue(path.exists(), "the authenticated scoped producer is missing")
        producer = path.read_text()
        harness = r"""
const calls = [];
let probeAttempts = 0;
global.location = {origin: 'https://forgejo.infra.supermorphic.com'};
global.window = {};
const options = JSON.parse(process.argv[1]);
const name = options.preparation ? 'career-ops-prepare-synthetic' : 'career-ops-flux-synthetic';
const confirmation = options.preparation ? 'enroll:career-ops:preparation-source' : 'enroll:career-ops:flux-source';
const text = (value) => ({textContent: value});
class Document {
  constructor(kind) { this.kind = kind; }
  querySelector(selector) {
    if (selector === 'input[name="name"]') return options.signed_out ? null : {value: 'synthetic-reader'};
    if (selector === '#scoped-access-form') return {getAttribute: () => '/user/settings/applications/tokens/new'};
    if (selector === '.flash-info p') return this.kind === 'created' ? text('a'.repeat(40)) : null;
    return null;
  }
  querySelectorAll(selector) {
    if (selector === '.flex-item') return this.kind === 'created' ? [new Row()] : [];
    return [];
  }
}
class Row {
  querySelector(selector) {
    if (selector === '.flex-item-title') return text(name);
    if (selector === '[data-modal-id="delete-token"]') return {getAttribute: () => '123'};
    return null;
  }
  querySelectorAll(selector) {
    if (selector === 'details ul') return [
      {querySelectorAll: () => [{textContent: 'supermorphic/career-ops', getAttribute: () => '/supermorphic/career-ops'}]},
      {querySelectorAll: () => [text(options.broad ? 'write:repository' : 'read:repository')]},
    ];
    return [];
  }
}
global.DOMParser = class {parseFromString(value) {return new Document(value);}};
global.fetch = async (url, args) => {
  calls.push({url, method: args.method || 'GET', body: args.body?.toString(), credentials: args.credentials});
  if (args.method === 'POST' && options.fail_post) throw new Error('sensitive server response');
  if (url.includes('/api/v1/repos/')) {
    probeAttempts++;
    if(options.fail_probe && probeAttempts === 1) throw new Error('sensitive probe error');
  }
  return {ok: true, url: url.endsWith('/tokens/new') && args.method === 'POST'
    ? location.origin + '/user/settings/applications' : url,
    text: async () => args.method === 'POST' ? 'created' : 'before',
    json: async () => ({id: 3, full_name: 'supermorphic/career-ops', private: true})};
};
(async () => {
  const result = await PRODUCER({origin: location.origin, repository: 'supermorphic/career-ops',
    tokenName: name, confirmation, preparation: options.preparation, resumeOnly: options.resume_only});
  const second = result.password || options.fail_probe ? await PRODUCER({origin: location.origin, repository: 'supermorphic/career-ops',
    tokenName: name, confirmation, preparation: options.preparation}) : null;
  console.log(JSON.stringify({result, second, calls, probeAttempts}));
})();
"""
        result = subprocess.run(
            [
                "node",
                "-e",
                harness.replace("PRODUCER", "(" + producer + ")"),
                json.dumps(
                    {
                        "broad": broad,
                        "signed_out": signed_out,
                        "fail_post": fail_post,
                        "resume_only": resume_only,
                        "fail_probe": fail_probe,
                        "preparation": preparation,
                    }
                ),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        return json.loads(result.stdout)

    def test_mints_exact_read_only_binding_and_retry_returns_same_pending_token(self):
        observed = self.run_producer()
        self.assertEqual(observed["result"], observed["second"])
        self.assertEqual(observed["result"]["token"]["scopes"], ["read:repository"])
        self.assertEqual(observed["result"]["token"]["repositories"], ["supermorphic/career-ops"])
        posts = [call for call in observed["calls"] if call["method"] == "POST"]
        self.assertEqual(len(posts), 1)
        self.assertIn("resource=repo-specific", posts[0]["body"])
        self.assertIn("scope=read%3Arepository", posts[0]["body"])
        self.assertNotIn("password", posts[0]["body"])
        self.assertTrue(
            any(
                call["url"].endswith("/api/v1/repos/supermorphic/career-ops")
                for call in observed["calls"]
            )
        )
        probe = next(call for call in observed["calls"] if "/api/v1/repos/" in call["url"])
        self.assertEqual(probe["credentials"], "omit")

    def test_preparation_uses_distinct_pending_identity_and_exact_read_scope(self):
        observed = self.run_producer(preparation=True)
        self.assertEqual(observed["result"], observed["second"])
        self.assertEqual(observed["result"]["token"]["name"], "career-ops-prepare-synthetic")
        self.assertEqual(observed["result"]["token"]["scopes"], ["read:repository"])
        self.assertEqual(len([c for c in observed["calls"] if c["method"] == "POST"]), 1)

    def test_broader_server_readback_does_not_deliver_a_credential(self):
        observed = self.run_producer(broad=True)
        self.assertEqual(set(observed["result"]), {"error"})

    def test_signed_out_session_does_not_mint(self):
        observed = self.run_producer(signed_out=True)
        self.assertFalse(any(call["method"] == "POST" for call in observed["calls"]))
        self.assertEqual(set(observed["result"]), {"error"})

    def test_ambiguous_create_failure_is_not_retried_and_hides_server_details(self):
        observed = self.run_producer(fail_post=True)
        self.assertEqual(set(observed["result"]), {"error"})
        self.assertNotIn("sensitive", observed["result"]["error"])
        self.assertEqual(len([c for c in observed["calls"] if c["method"] == "POST"]), 1)

    def test_resume_without_pending_receipt_does_not_create_another_token(self):
        observed = self.run_producer(resume_only=True)
        self.assertEqual(set(observed["result"]), {"error"})
        self.assertFalse(any(call["method"] == "POST" for call in observed["calls"]))

    def test_transient_read_failure_retries_proof_using_the_same_token(self):
        observed = self.run_producer(fail_probe=True)
        self.assertEqual(set(observed["result"]), {"error"})
        self.assertEqual(observed["second"]["token"]["id"], 123)
        self.assertEqual(observed["probeAttempts"], 2)
        self.assertEqual(len([c for c in observed["calls"] if c["method"] == "POST"]), 1)


if __name__ == "__main__":
    unittest.main()
