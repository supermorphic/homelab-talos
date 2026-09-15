# Private web search and extraction

## Purpose and ownership

Provide reusable public-web discovery and extraction for internal automation, as
specified in [issue 425](https://github.com/supermorphic/homelab-talos/issues/425).
SearXNG discovers URLs; Crawl4AI retrieves and extracts their content.

Prefer the supported upstream APIs for the first deployment. Use native Crawl4AI
authentication and network safeguards together with cluster-private Services and
Cilium policies. Add an application adapter only when a required invariant cannot
be enforced through supported upstream or generic platform controls. Reducing the
apparent API surface is not sufficient justification for an adapter.

Consumers own queries, allowed domains, URL selection, workflow budgets, caching,
evidence qualification, normalization, and inference. This platform does not
receive consumer policy, workflow state, prompts, or model credentials.

## Service interfaces

The selected design exposes SearXNG's JSON search API and Crawl4AI's authenticated
`POST /crawl` API. A response-limiting proxy preserves the native API while
protecting clients from oversized responses. It does not combine searches and
retrievals, transform results, or implement the Tavily API.

The consumer flow is:

```text
consumer -> SearXNG JSON search -> consumer selects approved public URLs
         -> Crawl4AI through bounded-response proxy -> consumer normalization
         -> consumer-owned evidence/cache and inference
```

Use one explicit HTTPS URL per normal extraction request. A representative native
Crawl4AI request uses the supported typed configuration:

```json
{
  "urls": ["https://example.com/document"],
  "browser_config": {
    "type": "BrowserConfig",
    "params": {"text_mode": true, "verbose": false}
  },
  "crawler_config": {
    "type": "CrawlerRunConfig",
    "params": {
      "cache_mode": {"type": "CacheMode", "params": "bypass"},
      "page_timeout": 15000,
      "verbose": false,
      "screenshot": false,
      "pdf": false
    }
  }
}
```

A consumer checks each result's `success`, `status_code`, `error_message`,
`redirected_url`, and `markdown` fields. Top-level success alone does not prove a
successful fetch. Use the actual final URL for provenance and reapply consumer
source restrictions before admitting text as evidence. Retrieval does not assert
document activity, publication date, employer identity, or evidence quality.

Use deterministic extraction without LLM credentials. Text-only mode, content
selectors, and pruning can reduce typical output, but are not maximum-size
controls. The Docker API uses the browser path for ordinary pages; do not introduce
a custom SDK service solely to obtain a lighter static fetch path.

## Authentication and trust boundaries

Give each consumer a data-scoped JWT. Never give a consumer the static administrative
API token or the signing key. The pinned server verifies JWT expiry, rejects
administrative actions for a data principal, and rejects dangerous caller-provided
browser, code, proxy, and filesystem configuration.

Prepare an operator-run issuance and rotation workflow using the repository's SOPS
conventions. The upstream token endpoint requires an operator credential and issues
short-lived data tokens; a data token cannot mint its replacement. Document expiry
and rotation explicitly without placing the administrative credential in n8n.
Credential lifecycle does not itself justify a retrieval adapter.

Keep inline code and hooks disabled and provide no external LLM credentials. Use
cluster-private Services and explicit Cilium caller selectors. Permit only approved
consumer and monitoring paths. No public ingress or operator UI is needed.

Cilium permits cluster DNS and public HTTPS while excluding private, loopback,
link-local, metadata, service, pod, node-management, and other reserved destinations.
Account for globally addressed cluster identities as well as private CIDRs.
Crawl4AI's application-level destination validation and DNS-pinning proxy provide an
independent boundary; validate their behavior with negative runtime tests.

Distinguish the public/private network boundary from consumer evidence-domain
restrictions. Consumers filter discovered URLs before fetching and validate final
URLs before using their text. A `site:` query alone is not source validation.
Do not add consumer-specific posting or employer policy to the infrastructure.
A requirement to prevent every public cross-domain redirect before navigation would
be an additional invariant needing explicit enforcement, beyond final-source checks.

## Response limits and crawler resource limits

Keep three different limits explicit:

1. **Incoming API request:** Crawl4AI's `limits.max_body_bytes` applies to API input.
2. **Outgoing API response:** a finite proxy buffer limit rejects an oversized native
   response before the consumer receives or parses it.
3. **Crawler work:** pod memory, CPU, concurrency, page timeout, and the server's
   finite `limits.wall_clock_s` constrain browser execution.

A response cap does not bound bytes already downloaded or memory already used by
Chromium. Resource limits do not establish a precise per-page byte limit. Do not
claim either property from a client-side text truncation setting.

The generic proxy uses Envoy's supported Lua response API to request full
body buffering, a finite protocol-appropriate buffer limit, and an explicit length
check. Request identity encoding and reject unexpected encoded responses so a small
compressed body cannot expand without a bound in n8n. Return an error, never a
truncated successful JSON document. Keep this operator-owned code small and free
of retrieval, domain, or consumer-specific logic.

Use an HTTPRoute-targeted `EnvoyExtensionPolicy` with Lua `body(true)`, which also
handles empty bodies. Enable the supported Lua extension in Envoy Gateway. Configure
both `ClientTrafficPolicy.connection.bufferLimit` for HTTP/1.1 and
`ClientTrafficPolicy.http2.initialStreamWindowSize` for HTTP/2; the controller
translates them separately. Set the HTTP/2 connection window at least as large as
the stream window. Isolate the private listener so these limits do not change other
applications' response behavior.

Listener limits alone do not cap streaming responses. Verify HTTP/1.1 and any enabled
HTTP/2 behavior, exact boundaries, chunked bodies, empty bodies, encoded responses,
and filter execution failure. Bind the policy to the crawler route and prevent
consumers bypassing it through the raw backend Service. The current repository has
not enabled these policies; deployment requires reviewed Git configuration and live
acceptance. Use supported Envoy Gateway resources where available rather than an
unnecessary standalone application or experimental filter.

Select the production response cap from representative complete native results,
including their HTML and metadata overhead. A small threshold in an isolated probe
proves enforcement behavior; it is not production resource sizing.

Keep a finite global crawler wall-clock deadline as well as client HTTP timeouts.
Do not claim that a client disconnect immediately cancels a native backend crawl.
Consumers reject late results and preserve their own deadlines and retry budgets.
If exact per-page downloaded-byte bounds or immediate backend cancellation remain
mandatory acceptance requirements, resolve those independently before activation;
they are not established by the response-size control.

## Flux, storage, versions, and operations

Use the existing `automation` grouping with app-local Flux Kustomizations and native
workloads. Keep discovery and extraction independently restartable, initially with
one replica each. Preserve restricted Pod Security: non-root execution, dropped
capabilities, no privilege escalation, runtime-default seccomp, no host networking
or mounts, and no Kubernetes service-account token.

Keep non-secret configuration in Git and runtime storage disposable. SearXNG does
not need Valkey for the private API shape with dependent features disabled. Retain
the official Crawl4AI container's password-protected loopback Redis only as disposable
runtime state; do not introduce a separate durable database or result cache.

Reviewed starting versions are SearXNG `2026.9.15-ca4965040`, Crawl4AI `0.9.3`,
and the existing Envoy Gateway `v1.8.2`. Pin reviewed image digests and recheck
releases and advisories before activation. Do not claim automated update coverage
until the repository's actual update mechanism is verified.

Use health/readiness probes, internal Gatus checks, and existing workload/resource
monitoring. Add a ServiceMonitor only for a verified working upstream metrics
interface. Report aggregate engine and extraction failures without queries, full
URLs, page text, authorization headers, or consumer workflow context in logs or
metrics labels. Review upstream monitor/cache persistence for the same privacy goal.

Measure baseline and representative CPU/memory for search, static documents,
JavaScript-rendered documents, and a small concurrent burst before final sizing.
Test a small engine set from the homelab egress path. Workstation results do not
establish cluster-egress reliability or CAPTCHA behavior.

## Validation and rollout

Use synthetic inputs and public documents. Register controlled runtime experiments
with bounded resources, ownership, evidence, and cleanup. Keep ordinary verification
observational and use only approved task-scoped credentials.

Acceptance covers native API requests and responses; data-token authorization;
disabled dangerous features; public and prohibited destinations; static and
JavaScript-rendered documents; redirects and final-source validation; response
limits; timeouts; bounded consumer attempts; partial and total engine failure;
privacy; and resource measurements. A healthy empty search must remain distinct
from total upstream failure.

Before publication, commit the candidate and run
`mise exec -- just test ci-publish` from a clean feature worktree. Operator secrets
and required runtime acceptance precede activation. Merge needs explicit operator
authorization. Reconcile this specification with implemented and validated behavior.

## Required consumer follow-up

After implementation and platform acceptance are complete, create a new issue in
the private `career-ops` repository to wire up SearXNG and Crawl4AI. This is a
required completion task; do not create it before the platform is ready.

Direct APIs are not a wire-compatible Tavily endpoint. The issue must implement
bounded search, URL filtering, extraction, and response normalization while
preserving the existing consumer's logical budgets, direct ATS retrieval, cache,
source qualification, evidence handling, and inference boundary. Include data-token
provisioning/rotation, final-URL handling, size and timeout failures, accurate provider
attribution, compatibility tests, and an explicit hosted-provider rollback path.
Link the completed infrastructure change and acceptance evidence. Do not publish
private consumer implementation or policy in this repository.

## Status

The direct-API review selected native services with a generic response-size guard.
No application adapter or custom SDK worker is justified by the tested requirements.
The official Crawl4AI image passed fifteen isolated checks covering data JWTs,
configuration rejection, prohibited seed URLs, deterministic raw-HTML extraction,
and the distinction between incoming request and outgoing response size. Those
checks did not contact public pages or validate cluster network policy.

An isolated probe of the controller's pinned Envoy `1.38.3` image passed eight
response-boundary checks. With an illustrative 1 MiB cap, HTTP/1.1 and HTTP/2
responses at the limit passed, and responses one byte over the limit returned a
small error. HTTP/1.1 chunked bodies obeyed the same boundary. Compressed and empty
encoded responses returned a small error. Test containers were removed.

n8n `2.36.7` does not supply this protection: its HTTP Request transport configures
unlimited response length, and optional output optimization happens after receipt.
Likewise, the Crawl4AI probe produced a 1,693,205-byte response from a 288,304-byte
request under a 524,288-byte incoming request cap with deterministic extraction.

The proxy probe used direct Envoy configuration. Deployed Gateway policy translation,
filter-failure behavior, representative browser loads, production sizing, and cluster
acceptance remain unverified. These checks must pass before activation.
No service implementation, activation, or consumer follow-up issue is complete.

## References

- [SearXNG search API](https://docs.searxng.org/dev/search_api.html)
- [Crawl4AI v0.9.3](https://github.com/unclecode/crawl4ai/releases/tag/v0.9.3)
- [Crawl4AI server migration](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/MIGRATION.md)
- [Crawl4AI configuration](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/config.yml)
- [Crawl4AI authentication](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/auth.py)
- [Envoy flow control](https://www.envoyproxy.io/docs/envoy/v1.38.3/faq/configuration/flow_control.html)
- [Envoy Gateway Lua extensions](https://gateway.envoyproxy.io/v1.8/tasks/extensibility/lua/)
- [n8n HTTP Request options](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/)
- [n8n pinned HTTP transport configuration](https://github.com/n8n-io/n8n/blob/f09fcad454339ae8d16d88c85e2e4a38f85b1217/packages/%40n8n/backend-network/src/http/axios/request.ts#L35-L43)
- [n8n platform](023-n8n-workflow-automation-platform.md)
