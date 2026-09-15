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
The implemented consumer address is
`http://crawl4ai.envoy-gateway-system.svc.cluster.local:8080/crawl`; the managed
Envoy Service lives in the controller namespace. SearXNG JSON search uses
`http://searxng.web-research.svc.cluster.local:8080/search`.

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

### Credential revocation semantics

Once loaded by the server, administrative API-token rotation invalidates the old
token for future issuance and administrative API access. It does not revoke
already-issued data JWTs; those remain valid until expiry or signing-key replacement.

Revoking existing JWTs before expiry requires signing-key rotation. Revocation takes
effect when every serving worker has loaded the new key, not merely when the Secret
changes. It invalidates all JWTs signed with the old key; the native server has no
individual-token revocation operation. It does not retroactively cancel work already
admitted. Do not mix old-key and new-key server replicas behind one Service.
The agent remints through the native issuer after cutover. The deployment workflow
must prove this automatic cutover before activation.

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
consumer, monitoring, and SearXNG private-UI paths. The SearXNG UI uses the existing
internal Gateway; Crawl4AI remains a cluster-private API with no operator UI route.

### SearXNG private UI and Homepage

Expose the native SearXNG UI at `https://searxng.lab.supermorphic.com` with no login,
as explicitly requested by the operator. Support both HTML and JSON search formats.
Use an app-owned HTTPRoute attached to `networking/internal`, listener `https`, with
`external-dns.k8s.io/audience: internal` and the existing wildcard certificate.
Label the platform namespace for internal Gateway access. Permit the internal
Gateway data plane to reach SearXNG alongside the selected automation and monitoring
callers. Keep normal query and content logging disabled or minimized.

LAN clients and authorized Tailscale clients use the same private HTTPS URL. Follow
the existing lab-domain split-DNS and subnet-router path; no public Gateway route,
public DNS publication, Funnel, or separate Tailscale application exposure is needed.
The private network path provides the requested access restriction without adding
application login. Verify access from both LAN and Tailscale during activation.

Homepage discovers the UI through its existing HTTPRoute annotation mechanism.
Use the tile name `SearXNG`, description `Private web search`, and group `Platform`,
matching n8n and NocoDB. Set the href to the private HTTPS URL and the pod selector
to the SearXNG workload. Do not add a duplicate static services entry or a new
Homepage group. The existing Gatus tile already supplies the monitoring dashboard.

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
handles empty bodies. Envoy Gateway `1.8.2` enables this supported extension by default;
no shared-controller feature-flag change is required. Configure
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

The implementation selects a dedicated two-worker Envoy with
`connectionLimit.value: 4`, `maxRequestsPerConnection: 1`, and
`http2.maxConcurrentStreams: 1`. Both protocol buffers and HTTP/2 windows are 8 MiB.
The container limit is 256 MiB, with a budget of 32 MiB for four resident responses,
96 MiB for loaded overhead, and 64 MiB safety margin. Local load acceptance covered
four simultaneous responses retained by slow HTTP/1.1 and HTTP/2 consumers, excess
admission, and recovery. With responses held for six seconds per protocol, peak
sampled container memory was below 82 MiB (`podman stats`, 37 samples), and allocator
physical memory was below 51 MiB (528 samples). Container accounting includes memory
outside the allocator; the overhead budget conservatively exceeds this measured
whole-container peak before adding the separate response allowance and safety margin.
Repeat this measurement on the deployed architecture before activation; local ARM64
measurements alone do not establish the live AMD64 resource margin.
The generated `shutdown-manager` sidecar also receives an explicit 64 MiB memory
limit through the supported Deployment strategic-merge patch. The two container
limits enforce a 320 MiB ceiling across the Pod; the sidecar cannot consume an
unbounded amount outside the main Envoy container's budget.
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

### Gatus checks and existing monitoring precedent

Use the existing Gatus workload, its ServiceMonitor, and Prometheus alert path.
The reviewed live inventory and active Git configuration contain the same 30 check
names/groups. Current automation precedent separates one-minute availability
(`nocodb`, `n8n-readiness`) from five-minute synthetic execution
(`n8n-webhook-e2e`, `automation-data-e2e`). Media Integration supplies additional
authenticated reads, with explicitly limited evidence; its status-only native-health
checks do not prove successful searches or downloads. This addition follows the
automation canary model with a smaller external-request frequency.

Add these stable names under Gatus group `Automation`:

| Name | Interval | Request and required evidence |
| --- | --- | --- |
| `searxng` | 1m | GET `https://searxng.lab.supermorphic.com/healthz`; require HTTP 200. Covers private DNS, TLS, Gateway routing, and native service health, following existing application health checks. Browser acceptance separately verifies the UI. |
| `crawl4ai-readiness` | 1m | GET the credential agent's dedicated internal readiness endpoint; require HTTP 200 and explicit ready state. It reads cached state and must not mint or validate a JWT as a side effect. |
| `crawl4ai-e2e` | 15m | POST one fixed public HTTPS fixture URL through the same bounded Envoy crawl route as consumers. Require a successful native result, acceptable final URL/status, and an expected extracted-text marker. |
| `searxng-search-e2e` | 30m | Make one fixed synthetic JSON search through the automation Service path. Require a valid response with at least one usable candidate URL and no total configured-engine failure. Do not depend on exact ranking or result count. |

The crawl canary catches failures beyond process/token readiness: route/auth header
delivery, public DNS/HTTPS retrieval, browser operation, and extraction. It proves
one representative fetch, not every site's JavaScript or anti-bot behavior. The
search canary catches engines becoming unusable while the UI remains healthy.
One failed engine must not fail this check when another returns usable results.
Use synthetic fixtures and queries, never consumer research or private job data.

The steady-state schedule adds 96 top-level crawls and 48 searches per day, without
automatic retries. A search fans out to the configured finite engine set; a crawl
can fetch subresources. Use small fixtures, avoid overlap, bound time/output/work,
and include this load in resource measurements. Scheduled canaries do not consume
or change consumer workflow budgets. Deep SSRF, response-size, concurrency, and
JavaScript test suites remain registered acceptance workflows, not periodic Gatus jobs.

Gatus receives no Crawl4AI token. Permit only its selected workload through the
bounded crawl route, plus read-only access to the separate agent monitoring port.
Do not give it access to the credential-returning authorization endpoint, native
token issuer, or raw Crawl4AI backend. Hide detailed functional-check errors in the
Gatus UI, following existing automation and integration checks.

Add availability and missing-series alert coverage with activation: the existing
generic `GatusEndpointDown` rule does not cover group `Automation`. Treat a degraded
refresh with a usable token as a warning, not readiness failure. Functional failures
should persist across scheduled checks before alerting; size alert windows for the
15m/30m cadences rather than copying the five-minute canary thresholds. Search
failure can reflect an external engine problem, and crawler failure can reflect
the public fixture; retain that evidence limit in alerts. Activate the checks and
Homepage discovery with the services, rather than monitoring staged absent workloads.

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
Feasibility probes established native data-scope enforcement, caller configuration
and prohibited-seed rejection, and full-response limits for HTTP/1.1, HTTP/2,
chunked and encoded responses. These informed the selected native API and generic
proxy boundary. The earlier short-TTL lifecycle prototype used synchronous
validation; the implementation evidence below supersedes that request path.

n8n `2.36.7` does not supply the output bound: its HTTP Request transport configures
unlimited response length, and optional output optimization happens after receipt.
Likewise, a native Crawl4AI probe produced a 1,693,205-byte response from a
288,304-byte request under a 524,288-byte input cap with deterministic extraction.

### Implementation evidence

The staged source now contains native Deployments, a dedicated Envoy Gateway,
workload network policies, the cached credential agent, the atomic-bootstrap server
launcher, a guarded operator SOPS writer, private SearXNG routing and Homepage
discovery, and the four approved Gatus definitions. Flux units remain suspended;
no production bootstrap Secret or runtime consumer credential has been created.

The production credential agent's focused tests cover automatic issuance, idle
renewal, cached admission, malformed issuer responses, expiry and recovery,
generation-aware invalidation, bounded incoming/outgoing HTTP, and observability.
Two scheduling regressions prove failed renewal cannot starve active validation
and validation failures cannot postpone due issuance. The launcher tests include
detached, TERM-ignoring workers and browser descendants, Supervisor crashes,
withholding replacement when cleanup cannot be proved, and exclusion of ambient
provider credentials. Linux-only process behavior was tested in the pinned native
image, in addition to the host source suite.

Pinned `egctl 1.8.2` accepted and translated the production route and policies.
The generated configuration ran in Envoy `1.38.3` with the production agent and
native Supervisor, Redis, Gunicorn and Chromium. Credential-free crawl, caller
Authorization replacement, excluded routes, public-page extraction and final URL
checks passed. Native atomic bundle rotation preserved issued JWTs during an
admin-only change, denied subsequent issuance with the old admin token, revoked
old-key JWTs on signing-key replacement, and recovered automatically through the
agent. All old native and browser process identities were gone before accepting
the replacement. The client required no credential update or restart.

The four condition sets passed in Gatus `5.34.0` against actual local native
SearXNG and Crawl4AI services, including the public crawl fixture and a real search
query. The shared internal Gateway's translated access-log filter was tested in
native Envoy: SearXNG authority variants were omitted and an unrelated route's log
was retained. The agent has separate ServiceMonitor and credential degradation,
unavailability and missing-metrics alert rules. Rules live in the domain
`alerts/app` package in the monitoring namespace. Credential alerts activate with
native Crawl4AI; Gatus rules remain unselected until their four endpoint definitions
activate in the same change.

A sustained local run observed proactive renewal with the native 60-minute JWT
lifetime around half-life, then a successful credential-free crawl without a client
restart. Four simultaneous public static-page crawls returned successful native
responses of about 184 KiB to 1 MiB; the native container peaked at 772,530,176 bytes
with no recorded OOM events. Slow-consumer response-buffer measurements are recorded
in the aggregate-memory section. These are local ARM64 fixtures, not a complete
JavaScript-heavy or deployed AMD64 workload profile.

The registered source gate passes 61 focused tests on the host (one Linux-only
case skipped and separately passed in the native image), validates 22 rendered
resources against available schemas, and checks twelve alert rules, their temporal
Prometheus fixtures, and the agent's metric exposition. The registered local integration workflow uses current pinned
images and generated Gateway configuration, verifies native rotation/recovery and
all four Gatus checks, and removes its owned Podman resources. It requires public
internet access but no cluster credentials or production secret.

These results do not establish live
Kubernetes Secret projection, Cilium enforcement, n8n workflow continuity,
LAN/Tailscale access, or representative deployed resource margins. Complete those
acceptance gates before declaring the unattended platform ready or creating the
authorized career-ops integration issue.

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
- [Current Gatus checks](../../kubernetes/apps/monitoring/gatus/app/values.yaml)
- [Gatus operating conventions](../../kubernetes/apps/monitoring/gatus/README.md)
- [Media integration evidence boundaries](019-media-integration-health-gatus.md)
- [Private lab-domain Tailscale access](../guides/tailscale-lab-domain-access.md)
