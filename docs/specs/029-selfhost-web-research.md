# Private web search and extraction

## Purpose and ownership

Provide reusable public-web discovery through SearXNG and extraction through native
Crawl4AI. Consumers own queries, URL/domain selection, deadlines, retries, caches,
normalization, evidence qualification, and inference. The platform accepts no consumer
prompts, workflow state, model credentials, or business-specific policy.

Use supported native APIs and generic platform controls. An adapter is justified only
when a required invariant cannot be enforced otherwise; reduced apparent API surface alone
is insufficient. The small credential agent supplies missing transparent token lifecycle,
not a search/retrieval/consumer-policy service. This is not a Tavily-compatible endpoint.

The [packages](../../kubernetes/apps/web-research/kustomization.yaml) own deployments,
configuration, image pins, routes, policy, and monitoring. Source owns typed API examples
and exact limits; consumers must test compatibility with those native interfaces.

## Native interfaces and evidence

Consumers search through the native JSON API, select approved public URLs, call the
private exact `POST /crawl` route, then normalize complete native responses. Normal
extraction uses one explicit HTTPS URL and deterministic text extraction without LLM
credentials. Text selectors/pruning reduce typical output but are not maximum-size controls.

Inspect per-result success, status, errors, redirects, and extracted content; top-level
success alone does not establish a fetched document. Use the actual final URL for provenance
and reapply consumer restrictions before admitting text. A `site:` query is not source
validation. Retrieval does not establish publication date, document activity, employer
identity, or evidence quality. Preventing every public cross-domain redirect before
navigation would require a separate explicitly enforced invariant.

The loaded search-engine set is finite with no automatic fallback. Partial engine failure
is acceptable when remaining results meet consumer evidence/deadline budgets; preserve
actual engine provenance. Distinguish a healthy empty result from total provider failure.
Private access does not hide queries or the platform's outbound address from providers.

## Automated authentication

Authorized workloads use a stable endpoint without storing data JWTs or administrative
credentials, manually renewing them, updating Secrets, or restarting consumers on expiry.
Cilium workload admission identifies the caller workload, not individual n8n workflows;
caller-supplied identity headers are not trusted. Consumers cannot reach `/token`,
administrative/streaming APIs, the raw backend, or credential agent.

Envoy `ext_authz` obtains a current data JWT from the platform agent and overwrites upstream
`Authorization` on each admitted call. Never return it to clients. The agent sees no crawl
body, fetches no documents, and implements no content/cache/domain policy. Ignore incoming
authorization and never log headers. Fail closed with bounded authentication timeouts,
no route recomputation, and a fixed issuer backend that cannot recurse through the proxy.

Native JSON token issuance does not match n8n OAuth2 renewal or static header credentials.
The in-memory agent avoids runtime Secret writes and consumer convergence dependencies.
It needs no API authority, persistent volume, or consumer credential database. Platform
administrative/signing material stays in the backend namespace; neither Envoy nor n8n
receives it. Data JWTs remain transient in memory/request transport.

### Bootstrap, renewal, and failure behavior

SOPS retains the stable signing key and platform administrative API token. The native
issuer reads effective `config.yml`; an environment variable alone does not establish
issuance. Prepare private runtime configuration from projected material automatically.
The configured issuer subject needs a valid MX domain; DNS failure can prevent issuance,
although no email is sent. Startup retries automatically and never enables anonymous access
when material is missing or malformed.

Mint one candidate at a time. Bound issuer/validation time and response bytes, prohibit
redirects, and validate response identity, JWT scope/type/algorithm, and plausible expiry.
Before atomic replacement, prove backend acceptance with an authenticated side-effect-free
schema read; public health cannot establish credential validity. Decoded expiry guides
scheduling but the backend is the authority.

Renew proactively with bounded jitter/backoff and clock margin. Admit immediately from
an unexpired, backend-validated in-memory token; no synchronous mint/schema request occurs
per admission. Serialize due background validation, renew while idle, and ignore late results
for superseded generations. A real validation `401` invalidates that generation. Timeout,
`5xx`, and ambiguous errors degrade health while preserving safely usable cached access;
the validation cadence is not a hard cache expiry. The backend still validates each crawl.
Read the projected administrative file afresh for issuance so replacement is observed.

When no usable token remains, deny with `503 platform_auth_unavailable`; an absent/crashed
agent or auth timeout also fails closed. Never substitute administrative or anonymous
access, broaden authority, or replay a crawl POST during authentication repair.
Expose token-free refresh/validation freshness, failures, usable expiry, and separate
liveness/readiness. Transient early-renewal failure warns without disabling valid access.

Agent restart mints anew; consumer restart uses the same endpoint. Backend restart retains
its stable signing key. Reconciliation restores routing, auth policy, and agent together;
no recovery phase may expose an unauthenticated crawl route.

### Bootstrap replacement and revocation

The native server does not support overlapping signing keys. The launcher watches the
projected versioned bundle, snapshots it consistently, renders memory-backed private
configuration, and replaces its own native child after validated change. Do not use `subPath`
for this bundle. Verify worker/browser shutdown and complete readiness cutover. A sidecar
cannot restart another container. This requires no Secret writes, workload patches, or
consumer restart.

Administrative-token rotation stops future issuance with the old value but does not revoke
already issued data JWTs. Signing-key rotation invalidates old JWTs only after every serving
worker loads the new key; do not mix generations behind one Service. It affects all old-key
JWTs and cannot cancel admitted work. There is no individual-token revocation endpoint.

A key may change after validation. The agent does not receive each crawl's eventual `401`,
so cutover can fail requests until background validation/renewal repairs cached authority.
Promise automatic recovery, not zero failures or next-request recovery. No possibly started
crawl is replayed. If issuing authority is unavailable/revoked, close admission when cached
validity expires; the agent cannot grant itself new authority.

## Network, privacy, and runtime boundaries

The native data principal cannot administer the backend or supply dangerous browser,
code, proxy, or filesystem configuration. Keep hooks/inline code disabled and provide no
external LLM credentials. These upstream controls remain independent of the auth agent.

Cilium admits only designated consumer, monitoring, and private-UI workloads and public
HTTPS/DNS egress. Exclude private, loopback, link-local, metadata, pod/service,
node-management, and reserved destinations, including globally addressed cluster identities.
The backend destination validator and DNS-pinning proxy provide an independent boundary;
negative runtime tests must prove it. Do not infer SSRF protection from private ingress.

SearXNG's native UI has operator-approved private access without application login, using
existing LAN/Tailscale split DNS, internal Gateway TLS, and Homepage route discovery.
Crawl4AI remains a private API without a UI/public route. Do not introduce public DNS,
Funnel, extra gateways, or duplicate static Homepage entries.

Use non-root restricted workloads without host networking/mounts or service-account tokens.
Discovery and extraction restart independently with disposable runtime storage. Backend-local
Redis is disposable implementation state, not a durable result cache. Do not add a durable
search cache/database without demonstrated need. Keep queries, full URLs, page text,
authorization, and consumer context out of logs, metrics labels, and monitoring UI errors.

## Response and work limits

Incoming request size, outgoing response size, and browser work are separate controls.
A finite full-response proxy buffer rejects oversized responses before consumer parsing;
never report truncated successful JSON. Require identity encoding and reject unexpected
encoded responses to avoid unbounded decompression. Empty/chunked bodies, filter failure,
and all enabled HTTP protocols need direct checks. Listener limits alone do not cap streams;
bind the full-body guard to the exact route and prevent raw-backend bypass.

Envoy may reject its buffer before the Lua guard runs, yielding a fixed plain-text `500`;
the guard's own rejection is a bounded JSON `502`. Consumers treat both as failed crawls.
Acceptance uses a deterministic fixture independently exceeding the production cap; an
arbitrary upstream error is not proof of enforcement. Select caps from representative
complete native responses including HTML/metadata overhead, not a tiny proof fixture.

Response caps do not bound bytes already downloaded or Chromium's prior memory use.
CPU/memory/concurrency, page timeout, and global crawler wall-clock limits constrain work
without promising exact per-page download caps or instant cancellation on disconnect.
Consumers reject incomplete HTTP responses even after a `200` header, reject late results,
and retain independent deadline/attempt budgets.

### Aggregate proxy memory bound

Per-response buffering must be paired with an effective per-pod concurrency bound:

```text
response cap × concurrent resident responses
  + measured loaded overhead + safety margin <= memory budget
```

The budget fits both container and pod limits, including shutdown-manager memory. Prove
admission across workers, connections, routes, and protocols; rate limits or HTTP/2
per-connection stream limits alone are insufficient. Count slow-client retained bodies
as well as filling responses. Source owns current cap, connection controls, and allocations.
Measure representative concurrent loaded overhead rather than idle memory. Acceptance must
fill simultaneous near-cap responses, stall consumers, exceed concurrency with bounded
overload failure, and prove recovery without OOM/restart. Retain measurements in evidence,
not a spec execution diary.

## Monitoring and acceptance boundaries

Use the existing Gatus/Prometheus/alert pipeline. Private UI health and cached agent readiness
are observational; readiness probes must not mint/validate as a side effect. Separate bounded
synthetic search/crawl canaries exercise actual native results through the same consumer
paths. Search accepts usable results from either configured engine rather than exact rankings;
crawl checks requested/final URL and a fixed public fixture marker. Neither proves every
site's JavaScript, anti-bot behavior, or provider reliability.

Keep canaries infrequent, small, non-overlapping, and retry-free; account for provider fan-out
and fetched subresources in resource sizing. Scheduled checks do not change consumer budgets.
Gatus receives no data/administrative token and cannot reach issuer or credential-returning
auth endpoints. Missing series after activation is failure; transient refresh trouble with
usable access is a warning. Size alert windows for actual functional-check cadence.
Monitoring does not gate service availability. Do not add speculative metrics interfaces.

Source checks establish configuration contracts; disposable experiments establish selected
components. Deployed acceptance must cover real Gateway/Cilium/n8n caller paths, native
scope and denials, SSRF, redirects, static/JavaScript extraction, full-body/aggregate limits,
deadlines, privacy, restart, and cleanup. Cluster egress can differ from workstation behavior.

Authentication acceptance separately proves cold-start issuance, renewal/idle continuity,
header replacement, cached admission without synchronous validation, single background
checks, transient validation failure, actual expiry, invalidation, superseded late responses,
and coordinated bootstrap replacement. Client restarts and absence of required policy fail
closed. Keep controlled experiments in registered tests with approved scoped authority.
Gatus/UI enrollment follows deployed acceptance; CI alone cannot establish readiness.

Consumers retain bounded direct APIs, source qualification, cache/evidence/inference
boundaries, accurate provider attribution, compatibility tests, and an explicit hosted-provider
rollback path. Consumer implementation may proceed independently, but production cutover
depends on platform acceptance. Image/auth/upstream capability changes require fresh affected
proof rather than transferring old acceptance by assumption.
