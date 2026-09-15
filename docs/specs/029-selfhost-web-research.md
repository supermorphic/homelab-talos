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

Unattended operation is a required invariant. The platform owns authentication,
issuance, renewal, and recovery from expired backend credentials. The selected
generic authentication boundary is Envoy `ext_authz` plus a small credential agent
beside Crawl4AI. It preserves the native crawl operation and does not implement a
search, extraction, or consumer-policy adapter.

Consumers own queries, allowed domains, URL selection, workflow budgets, caching,
evidence qualification, normalization, and inference. This platform does not
receive consumer policy, workflow state, prompts, or model credentials.

## Service interfaces

The selected design exposes SearXNG's JSON search API and Crawl4AI's authenticated
`POST /crawl` API. Envoy handles authentication and response limits while
preserving the native request and successful response. It does not combine searches
and retrievals, transform results, or implement the Tavily API.

The consumer flow is:

```text
consumer -> SearXNG JSON search -> consumer selects approved public URLs
         -> private Envoy POST /crawl -> native Crawl4AI -> consumer normalization
                    |
                    +-> ext_authz credential agent -> native POST /token

consumer-owned evidence/cache and inference follow normalization
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

## Automated authentication

### Required invariant and selected boundary

An authorized consumer can keep using the service without holding a Crawl4AI token,
manually obtaining or rotating a JWT, editing a Secret, restarting its process, or
making a Git commit because a runtime credential expired. n8n stores no Crawl4AI
administrative credential, signing key, or data JWT.

Use the private caller's Cilium workload identity for admission to the dedicated
Envoy Service. This identifies the authorized workload, not an individual n8n
workflow. Do not trust a caller-supplied identity header. Restrict the route to exact
`POST /crawl`; consumers cannot reach `/token`, administrative operations, streaming
crawls, the raw backend Service, or the credential agent. Keep monitoring separate.

Envoy calls a small platform-owned credential agent through supported
`SecurityPolicy.extAuth`. The agent returns a current data-scoped JWT to Envoy, which
overwrites the upstream `Authorization` header on every admitted request. Do not
forward that header to the client. The agent receives no crawl request body and
does not fetch target pages, parse documents, filter domains, cache results, combine
searches, or transform successful crawl responses.

HTTP `ext_authz` includes any caller `Authorization` header in its check request.
The agent must ignore that value and must never log incoming headers. It uses only
its own platform-issued data JWT for the upstream header.

Keep the agent beside Crawl4AI with an in-memory token cache. It needs no Kubernetes
API credential, Secret-write permissions, persistent volume, or consumer credential
database. Configure `extAuth.failOpen: false`, `statusOnError: 503`, a finite auth
timeout, no route recomputation, and only `Authorization` in `headersToBackend`.
Use a fixed backend address, separate from the consumer-facing crawl route, to avoid
recursive authentication. Keep the existing full-response guard on the crawl path.

### Native capability evaluation

Crawl4AI `0.9.3` exposes a scriptable JSON `POST /token` with an email subject and
administrative API token. It issues a data JWT with a 60-minute lifetime. It has no
OAuth2 client-credentials grant, refresh token, individual JWT revocation endpoint,
or built-in consumer credential distribution. n8n's OAuth2 client sends form-encoded
OAuth requests, which do not match this native JSON endpoint. A static header-auth
credential does not implement renewal.

The native endpoint remains the issuer; the agent supplies the missing lifecycle
and transparent delivery. A periodic job updating a consumer Secret would not solve
an unchanged n8n process retaining its stored credential. Envoy's supported Secret
credential-injection mechanism is another possible delivery path, but needs a token
writer, runtime Secret ownership, and Secret-to-proxy convergence. The selected
in-memory agent avoids those dependencies and gives a direct unavailable condition.
Do not inject the administrative token into crawl requests or use a manually issued
long-lived JWT as the steady-state solution.

### Bootstrap and renewal

SOPS bootstraps the long-lived platform API token and stable signing key. Mount the
API token only into the credential agent and native server; the signing key is
needed only by the native server. Neither reaches the consumer or Envoy. Keep these
values in the platform namespace. Ephemeral data JWTs exist only in the agent and
the Envoy-to-Crawl4AI request path; they are not Git-managed Secret values.

The native `/token` implementation reads `security.api_token` from `config.yml`;
setting `CRAWL4AI_API_TOKEN` alone is insufficient for issuance. Prepare the effective
configuration automatically in a private runtime volume from the non-secret template
and mounted bootstrap material. Do not write rendered secret configuration to Git
or logs. Keep `SECRET_KEY` stable across workers and ordinary server replacement.

Every issuance checks the email subject's MX record. Use a configured platform
subject with a valid MX domain; no email is sent. DNS failure is an issuance failure.
Startup waits and retries automatically until the authenticated issuer is usable.
Missing or invalid bootstrap material must never enable an unauthenticated server.

The credential agent must:

1. Mint automatically on startup, with one issuance in progress at a time.
2. Bound issuer and validation requests by time and response bytes, prohibit redirects,
   and validate JSON content type, field types, returned email and bearer token type,
   JWT type and algorithm, subject, data scope, and plausible future expiry.
3. Validate each candidate with a bounded, authenticated, side-effect-free native
   `GET /schema` before atomically replacing the current token. Decoded expiry is a
   scheduling hint; the backend is the authentication authority. `/health` cannot
   establish token validity because it is public.
4. Renew proactively around halfway through the native lifetime, with bounded jitter
   and retry backoff. Keep a small expiry margin for clock skew and request admission.
5. Serve ordinary admissions immediately from the previously validated in-memory
   JWT, checking expiry and known invalidation locally. Do not call `GET /schema`
   or mint a new token on every admission. Revalidate asynchronously at most once
   per minute while actively used, with one validation in progress at a time.
   An admission can schedule a due check but must not wait for it while its cached
   token remains usable. Proactive renewal continues independently during idle periods.
6. On a native validation `401`, invalidate that token generation and initiate
   renewal. Ignore a late validation result for a token already replaced. A timeout,
   `5xx`, or other ambiguous validation response marks health degraded without
   evicting the token or denying otherwise usable admissions. The validation cadence
   is not a hard cache expiry: continue using an unexpired, previously validated
   token until its expiry margin or a confirmed invalidation. Crawl4AI still checks
   the JWT on every actual crawl request.
7. Read the projected API-token file afresh for issuance rather than retaining an
   environment-variable snapshot. A replacement credential is used automatically.

Consumers always use the same endpoint. Each Envoy authorization call obtains the
current JWT, so rotation does not require changing a consumer Secret, workflow
credential, environment variable, or process. No credentials are returned to n8n.

### Failure and restart behavior

If proactive refresh or background validation fails transiently, retain the last
backend-validated JWT while it remains usable. Mark health degraded and retry
automatically. Do not mark a usable service unready or block admissions merely
because an early renewal or periodic validation attempt failed. Once no usable
credential remains, deny admission with `503 platform_auth_unavailable`. An agent
timeout, crash, or missing endpoint also fails closed. Never fall back to anonymous
access, inject an administrative credential, broaden permissions, or retry a crawl
POST as part of authentication recovery.

Expose token-free refresh and validation health, last successful refresh and validation
times, seconds until usable expiry, and bounded failure counters. Distinguish process
liveness, usable access,
and degraded refresh health. A separate readiness endpoint returns `200` only while
access is safely usable; liveness does not depend on a working issuer. Alert before
expiry and on unavailable authentication;
never log JWTs, authorization headers, issuer request bodies, or signing material.

An agent or consumer restart requires no retained data JWT. Agent startup mints a
new token; a restarted consumer uses the same endpoint. An ordinary Crawl4AI restart
retains its stable signing key and recovers through startup/readiness ordering.
Reconciliation must restore the route, authorization policy, and agent together and
must not make an unauthenticated route usable during recovery.

The pinned upstream has no overlapping signing-key support. Bootstrap replacement
uses a small launcher in the server container that watches the projected bootstrap
volume, takes a consistent snapshot, prepares private configuration, and replaces
its own native child process when that snapshot changes. Mount the versioned bundle
without `subPath`; render configuration mode `0600` on a memory-backed runtime
volume. An ordinary sidecar cannot restart a different container. The launcher also
restarts an exited
server with bounded backoff. This needs no Kubernetes Secret writes, Deployment
patch permissions, or consumer restart. Readiness covers the complete cutover;
malformed or absent material must not start an unauthenticated process. Validate
shutdown of the server's workers and browser children before replacement.

Do not mix old-key and new-key server replicas behind one Service. A signing-key
cutover invalidates existing JWTs, and the agent remints through the native issuer. The
deployment workflow must prove this automatic cutover before activation. Native
API-token replacement alone does not revoke already-issued JWTs.

A key can change after successful token validation. A cutover can therefore produce
transient backend authentication/unavailable responses until background validation
or renewal detects and repairs the cached credential. `ext_authz` runs before the
crawl and does not observe its eventual `401`. Immediate invalidation applies to a
real `401` observed by the agent; the initial design adds no response-feedback path
to report every crawl failure back to it. Recovery is automatic after the next
successful validation/renewal cycle, rather than guaranteed on the next admission.
Do not promise zero failed requests or replay a possibly-started crawl.
If the platform's issuing authority has itself been
revoked or is unavailable, keep access closed when cached authority expires; the
agent retries with its configured authority and cannot grant itself new authority.

## Network and caller configuration boundaries

The pinned server verifies JWT expiry, rejects administrative actions for a data
principal, and rejects dangerous caller-provided browser, code, proxy, and filesystem
configuration. The authentication agent does not replace these upstream controls.

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

### Aggregate Envoy memory bound

The per-response cap must be paired with an enforced bound on simultaneous buffered
responses. Establish this invariant for each Envoy pod:

```text
response_cap × max_concurrent_buffered_responses
  + measured_Envoy_overhead + safety_margin
  <= Envoy_memory_budget
```

The Envoy memory budget must fit both its container limit and the available pod
memory limit. Measure overhead under representative concurrent load, including
request/connection buffers, allocation or copy overhead, and other traffic sharing
the proxy; do not substitute idle memory usage. Record the cap, concurrency bound,
measured overhead, and explicit safety margin with the sizing evidence.

Leave the supported Envoy concurrency/admission control to implementation. Prove its
effective bound per pod across workers, connections, routes, and enabled protocols.
Count responses retained for slow consumers as well as responses still being filled.
A request-rate limit or a per-connection HTTP/2 stream limit alone does not establish
this aggregate bound.

Acceptance must exercise simultaneous near-cap responses and slow consumers at the
allowed concurrency, then exceed that concurrency. Excess work must receive a
bounded overload failure without unbounded queueing or buffering. Verify peak memory
stays within the budget and that the proxy recovers without an OOM kill or restart.

### Crawler deadlines

Keep a finite global crawler wall-clock deadline as well as client HTTP timeouts.
Do not claim that a client disconnect immediately cancels a native backend crawl.
Consumers reject late results and preserve their own deadlines and retry budgets.
If exact per-page downloaded-byte bounds or immediate backend cancellation remain
mandatory acceptance requirements, resolve those independently before activation;
they are not established by the response-size control.

## Flux, storage, versions, and operations

Use app-local Flux Kustomizations and native workloads in a dedicated `web-research`
platform namespace, separate from consumer credentials and workloads. This isolation
supports the automated credential boundary. Keep discovery and extraction
independently restartable, initially with one replica each. Preserve restricted
Pod Security: non-root execution, dropped
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

Before deployment implementation, establish the automated authentication design with
an isolated lifecycle spike. Before activation, repeat the relevant checks through
the deployed Gateway policies, Cilium callers, and an unchanged n8n HTTP Request
consumer. Required evidence includes automatic cold-start issuance, proactive
renewal, credential-free consumer continuity, header replacement, data scope,
restart/reconciliation, expired and key-invalidated token recovery, cached-token
continuity during refresh failure, observable failure, and fail-closed expiry.
Verify that admissions using a usable cached JWT perform no synchronous backend
validation, that an active burst schedules at most one due background check, and
that transient validation failure preserves usable access. Cover actual expiry,
validation `401`, and a late `401` for a superseded token generation separately.
Explicitly test bootstrap replacement and coordinated server rollout. Keep the
route unavailable if a required policy or usable credential is absent.

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
source qualification, evidence handling, and inference boundary. Include workload
admission with no stored Crawl4AI credential, final-URL handling, platform authentication
and size/timeout failures, accurate provider
attribution, compatibility tests, and an explicit hosted-provider rollback path.
Link the completed infrastructure change and acceptance evidence. Do not publish
private consumer implementation or policy in this repository.

## Status

The selected design combines native services, a generic response-size guard, and an
Envoy `ext_authz` credential agent. Fully automated authentication supersedes the
earlier proposal to distribute manually rotated data JWTs to consumers. No search,
extraction, or consumer-policy adapter is needed.
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

An additional isolated lifecycle spike passed 21 assertions through Envoy `1.38.3`
and the native Crawl4AI `0.9.3` endpoints. It covered issuance, proactive renewal,
credential-free client continuity, header overwrite, route restriction, data scope,
agent/consumer restart, automatic bootstrap-file reload and native server restart,
signing-key invalidation, issuer-credential replacement,
cached access during refresh failure, observable degradation, expired-token recovery,
and fail-closed expiry or unavailable agent. The fixture shortened the JWT lifetime
to 18 seconds and supplied a loopback MX DNS answer; it used no external network or
production secrets. All disposable test containers were removed.

Four focused checks with synthetic HTTP responses verified that the earlier
per-admission prototype retained its cached JWT on ambiguous validation failures.
That prototype still denied the affected admission. The revised cached-admission
design removes this dependency; its non-blocking validation behavior and aggregate
Envoy memory/concurrency invariant require new implementation acceptance evidence.

This proves the local lifecycle mechanism using a single native Uvicorn process,
not deployed Kubernetes reconciliation, an actual n8n workflow execution, production
DNS reliability, Kubernetes Secret projection, or production supervisor/worker
shutdown. Invalid/simultaneous bootstrap changes, launcher failure, separate
liveness/readiness behavior, and malformed issuer-response rejection also remain
implementation acceptance tests. Those integration gates remain outstanding; do not report
the unattended platform ready before they pass.
No service implementation, activation, or consumer follow-up issue is complete.

## References

- [SearXNG search API](https://docs.searxng.org/dev/search_api.html)
- [Crawl4AI v0.9.3](https://github.com/unclecode/crawl4ai/releases/tag/v0.9.3)
- [Crawl4AI server migration](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/MIGRATION.md)
- [Crawl4AI configuration](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/config.yml)
- [Crawl4AI authentication](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/auth.py)
- [Envoy flow control](https://www.envoyproxy.io/docs/envoy/v1.38.3/faq/configuration/flow_control.html)
- [Envoy overload management](https://github.com/envoyproxy/envoy/blob/v1.38.3/docs/root/intro/arch_overview/operations/overload_manager.rst)
- [Envoy Gateway Lua extensions](https://gateway.envoyproxy.io/v1.8/tasks/extensibility/lua/)
- [Envoy Gateway external authorization](https://gateway.envoyproxy.io/v1.8/tasks/security/ext-auth/)
- [Pinned external-authorization translation](https://github.com/envoyproxy/gateway/blob/v1.8.2/internal/xds/translator/extauth.go)
- [Crawl4AI token endpoint](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/server.py#L581-L596)
- [Crawl4AI issuer DNS check](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/utils.py#L402-L409)
- [n8n HTTP Request options](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/)
- [n8n pinned HTTP transport configuration](https://github.com/n8n-io/n8n/blob/f09fcad454339ae8d16d88c85e2e4a38f85b1217/packages/%40n8n/backend-network/src/http/axios/request.ts#L35-L43)
- [n8n platform](023-n8n-workflow-automation-platform.md)
