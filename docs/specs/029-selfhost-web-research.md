# Private web search and extraction

## Purpose and ownership

Provide reusable public-web discovery and extraction for internal automation, as
specified in [issue 425](https://github.com/supermorphic/homelab-talos/issues/425).
SearXNG discovers URLs; Crawl4AI retrieves and extracts their content. A small
platform-owned adapter supplies authentication, request bounds, and the supported
Tavily-compatible search interface.

Consumers own queries, allowed domains, result qualification, workflow budgets,
caching, evidence, and inference. This platform does not receive consumer policy,
workflow state, prompts, or model credentials. It does not establish whether a
retrieved document satisfies a consumer's evidence requirements.

## Service interfaces

The primary interface is one authenticated `POST /search`. It composes discovery
and extraction within one caller deadline. An authenticated `POST /extract`
provides the same extraction behavior for one explicit public HTTPS URL.
SearXNG also retains a cluster-private JSON API for consumers that independently
select URLs. The adapter is the supported bounded extraction interface.

The supported search request subset is:

```json
{
  "query": "synthetic public research query",
  "include_domains": ["example.com"],
  "max_results": 2,
  "search_depth": "basic",
  "auto_parameters": false,
  "include_answer": false,
  "include_raw_content": "text",
  "include_images": false,
  "topic": "general"
}
```

Validate types strictly. Accept between 1 and 20 results and a nonempty domain
list. Reject unsupported search modes, answer generation, image requests, and
unknown fields. Do not implement the rest of the Tavily API without a demonstrated
consumer requirement.

A successful response includes a generated request ID and ordered results:

```json
{
  "request_id": "synthetic-request-1",
  "results": [
    {
      "url": "https://example.com/final-page",
      "title": "Example document",
      "content": "Discovery snippet",
      "raw_content": "Deterministically extracted public document text."
    }
  ]
}
```

`url` identifies the actual retrieved final URL. Original URL, redirect information,
source-engine metadata, timings, and partial failures may appear in additional
fields. Do not invent a Tavily-calibrated relevance score. Preserve discovery order
when extraction completes concurrently.

Return complete text within a finite service limit. Oversize content produces an
explicit failure; do not silently truncate text. Consumer-side truncation remains
a separate operation. Static and browser extraction produce deterministic text
without invoking a model. An extraction result does not assert document activity,
publication date, employer identity, or evidence quality.

## Request bounds and failure behavior

One search request performs one SearXNG discovery operation and at most
`max_results` top-level extraction attempts. Search-engine fanout stays within the
configured finite engine set. Do not add per-domain searches, replenish failed
candidates with further attempts, or invoke hosted fallback implicitly.

Filter discovered URLs against the request's domains before extraction. Domain
matching accepts the named domain and its subdomains, with a DNS-label boundary.
The allowed domains must also constrain document navigation and redirects. A
search engine's interpretation of `site:` is not an enforcement boundary.
Browser subresources may use other public HTTPS domains under separate finite
resource and byte limits; they cannot authorize navigation outside the request's
allowed document domains.

Use a caller-supplied timeout header, clamped by a finite server maximum. Include
queueing, search, extraction, and serialization in the request deadline. Cancel
outstanding work on timeout and client disconnect. Bound concurrent work and reject
excess admission explicitly. Browser work must stop when its owning request ends.

A healthy search with no matching results is a successful empty response. An
unavailable discovery service, total configured-engine failure, and total extraction
failure are execution errors. Partial successes can return usable results with
explicit failure metadata. Authentication, invalid input, saturation, oversize
responses, dependency failure, and deadline expiry have distinct documented HTTP
statuses and stable non-sensitive error codes.

## Flux and runtime shape

Use the existing `automation` grouping with app-local Flux Kustomizations and native
workload resources. Keep discovery and extraction independently restartable. Use
one replica per service initially. Preserve restricted Pod Security: non-root,
no privilege escalation, dropped capabilities, runtime-default seccomp, no host
networking or mounts, and no mounted Kubernetes service-account token.

Keep configuration in Git and mount only disposable runtime storage. No persistent
search-result datastore, authoritative crawler cache, worker fleet, or autoscaler
is introduced. SearXNG does not need Valkey for the private API configuration when
features depending on it are disabled. If the selected Crawl4AI server shape needs
its bundled loopback Redis, retain it only as disposable runtime state without a
separate exposed or durable database service.

The reviewed starting versions are SearXNG `2026.9.15-ca4965040` and Crawl4AI
`0.9.3`. Pin reviewed image digests and recheck releases and advisories before first
activation. Keep update detection consistent with the repository's actual update
mechanism. Do not claim automated update coverage until that mechanism is verified.

The runtime integration must demonstrate enforcement of navigation scope, downloaded
page bytes, output bytes, request cancellation, and container restrictions. An HTTP
response cap alone does not prove bounded page download or browser resource use.
Keep the production Flux unit suspended until its required configuration, operator
credentials, and runtime acceptance prerequisites are available.

## Network and authentication

Use cluster-private Services and narrowly selected consumer workloads. Permit n8n
only through explicit policy on both endpoints. Give monitoring access only to its
required health and metrics endpoints. Do not create a public route or anonymous
public search proxy.

Use a dedicated consumer credential, delivered through an operator-run SOPS writer.
Do not distribute the Crawl4AI administrative token to consumers. Keep backend
credentials separate from consumer authentication. Private TLS must protect any
credential-bearing endpoint exposed outside the pod or cluster-private transport
boundary selected for the deployment.

Apply independent Cilium network controls. Permit cluster DNS and public HTTPS;
exclude private, loopback, link-local, metadata, service, pod, node-management, and
other reserved destinations. Account for globally addressed cluster identities as
well as private CIDRs. Do not add arbitrary internal exceptions for the crawler.
Application controls must also reject private destinations and validate each
redirect and resolved address. Do not allow caller-provided proxies, browser
arguments, scripts, hooks, file URLs, downloads, deep crawling, PDF products, or
LLM extraction.

## Monitoring and privacy

Use startup, liveness, and readiness checks that distinguish process availability
from functional browser readiness. Add Gatus coverage for supported internal health
interfaces and standard workload/resource monitoring. Add a ServiceMonitor only
when the selected upstream metrics endpoint has been verified to work.

Report aggregate request outcomes, engine failures, deadlines, rejected work,
extraction failures, and resource usage. Do not log queries, full URLs, page text,
authorization headers, or consumer workflow context. Correlation IDs are generated
by the platform and contain no request data. Metrics labels have bounded cardinality.
No operator UI or Homepage tile is needed for an API-only first release.

## Validation and rollout

Use synthetic inputs and public documents. Local contract checks must cover:

- The supported request subset and compatible result envelope.
- Domain filtering before extraction, redirect scope, and actual final URL.
- Static and JavaScript-rendered content with exact expected fixture text.
- Authentication, disabled features, deadline expiry, disconnect cancellation,
  saturation, oversized pages, and oversized outputs.
- Private and reserved destinations, DNS changes, and redirect targets.
- Partial engine failure, total engine failure, and genuine empty searches.
- Finite extraction attempts, preserved result ordering, and no implicit retries.
- Absence of consumer content and credentials from logs and persisted artifacts.

Register runtime experiments as test workflows with bounded resources, ownership,
evidence, and cleanup. Keep ordinary verification observational. Use task-scoped
observer credentials for approved inspection and stop at RBAC boundaries.

Measure baseline and representative CPU and memory for discovery, static retrieval,
JavaScript rendering, and a small concurrent burst before finalizing resource
requests and limits. Verify candidate engines from the homelab egress path; a local
workstation result cannot establish cluster-egress reliability. Engine selection
remains provisional until that experiment passes.

Before publication, commit the candidate and run the repository-owned
`mise exec -- just test ci-publish` gate from a clean feature worktree. Secret
creation and privileged activation remain operator-run. Merge requires explicit
operator authorization. Reconcile this specification with implemented behavior
and retained validation evidence before merge.

## Required consumer follow-up

After implementation and platform acceptance are complete, create a new issue in
the private `career-ops` repository to wire up SearXNG and Crawl4AI. This follow-up
is part of completing the initiative; do not create it before the platform is ready.

The issue must provide the validated service address, authentication setup,
supported request and response contract, deadline-header binding, and accurate
provider attribution. Require preservation of direct ATS retrieval, source and
budget controls, caching, evidence handling, and the inference boundary. Include
compatibility tests and an explicit hosted-provider rollback path. Link the
completed infrastructure change and its acceptance evidence. Do not include private
consumer implementation or policy in this public repository.

## Status

The service boundary and compatibility direction are approved. Upstream research
and ten offline checks against the existing consumer interface are complete.
Runtime implementation, measurements, cluster acceptance, and the consumer follow-up
issue are not complete.

## References

- [SearXNG search API](https://docs.searxng.org/dev/search_api.html)
- [SearXNG container installation](https://docs.searxng.org/admin/installation-docker.html)
- [Crawl4AI v0.9.3](https://github.com/unclecode/crawl4ai/releases/tag/v0.9.3)
- [Crawl4AI server migration](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/MIGRATION.md)
- [Crawl4AI security verification](https://github.com/unclecode/crawl4ai/blob/v0.9.3/deploy/docker/SECURITY-VERIFY.md)
- [n8n platform](023-n8n-workflow-automation-platform.md)
- [Repository command lifecycle](../reference/repository-command-lifecycle.md)
