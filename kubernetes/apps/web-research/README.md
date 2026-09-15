# Private web research

SearXNG provides search and a private browser UI. Crawl4AI provides native page
extraction through a bounded Envoy route. Consumers own result selection, research
budgets, domain policy, caching, source attribution, and response normalization.
This is not an endpoint-only replacement for Tavily.

## Interfaces

| Interface | Address | Access |
| --- | --- | --- |
| Search UI | `https://searxng.lab.supermorphic.com` | Private LAN and existing Tailscale lab-domain access; no application login |
| Native JSON search | `http://searxng.web-research.svc.cluster.local:8080/search` | Selected n8n and Gatus workloads; query parameters `q` and `format=json` |
| Native crawl | `http://crawl4ai.envoy-gateway-system.svc.cluster.local:8080/crawl` | Selected n8n and Gatus workloads; exact `POST /crawl`; no consumer credential |
| Credential readiness | `http://crawl4ai-health.web-research.svc.cluster.local:9001/readyz` | Gatus; returns `{"ready":true}` only with a usable cached credential |

The dedicated Envoy Service lives in the Envoy Gateway controller namespace.
The native backend and credential-agent authorization port accept only that
dedicated proxy workload. They are not consumer interfaces.

Envoy replaces caller Authorization with a data-scoped JWT from the agent on each
admission. Admission reads an in-memory cache. A background worker obtains and
validates tokens, renews around half-life, and validates an actively used token at
most once per minute. Candidate validation also occurs after every issuance.
Neither n8n nor Gatus stores a Crawl4AI credential.

Transient renewal or validation errors retain a usable token and set degraded
metrics. Expiry or a confirmed validation `401` prevents further admission with
that token. The agent automatically retries issuance. A crawl can fail during key
cutover; the proxy never replays a crawl automatically.

## Limits and privacy

- Native API input: 512 KiB; crawl wall-clock budget: 75 seconds.
- Complete API response: 8 MiB. Encoded responses are rejected. Oversized responses
  return an error; a truncated response is never presented as successful native JSON.
- Envoy admits at most four connections, one request per connection and one HTTP/2
  stream per connection, across two workers. Its container memory limit is 256 MiB.
- The controller's `shutdown-manager` sidecar is separately limited to 64 MiB,
  making the hard ceiling across both Pod containers 320 MiB.
- The sizing budget is 32 MiB for resident responses, 96 MiB for loaded overhead,
  and 64 MiB safety margin. Local slow-consumer tests measured less than 82 MiB of
  container memory and 51 MiB of allocator physical memory. Repeat measurement on
  the deployed architecture, including the generated sidecar.
- These response limits do not bound downloaded page bytes or Chromium memory.
  Browser resources and deadlines are separate controls. A client disconnect does
  not prove immediate browser cancellation.
- Native application output is suppressed because errors can include page or query
  text. Crawl proxy access logs are disabled; the shared internal Gateway excludes
  SearXNG requests. Use health metrics and fixed synthetic probes for availability.
- The native loopback Redis is password-protected, memory-only, capped at 64 MiB,
  and has no persistent volume. Native task metadata can contain URLs until its
  one-hour TTL or process replacement. Consumers must not treat it as a durable cache.

## Monitoring and Homepage

The SearXNG HTTPRoute supplies the **Platform → SearXNG** Homepage card through
existing discovery annotations. The hostname uses the internal Gateway, internal
DNS audience, and existing wildcard TLS. There is no public route or Funnel.

The four approved Gatus endpoints are staged in
[monitoring/gatus-endpoints.yaml](monitoring/gatus-endpoints.yaml). Append them to
the existing Gatus endpoint array when activating monitoring; do not replace the
array with this fragment through Helm values merging.
Add `./gatus.yaml` to `alerts/app/kustomization.yaml` in the same Git change to
select their alert rules.

| Gatus name | Interval | Public internet dependency |
| --- | --- | --- |
| `searxng` | 1 minute | None for the private HTTPS health request |
| `crawl4ai-readiness` | 1 minute | The request is internal; automatic token issuance requires the subject domain's MX lookup |
| `crawl4ai-e2e` | 15 minutes | Fetches the fixed `https://example.com/` page and checks native extraction and final URL |
| `searxng-search-e2e` | 30 minutes | Queries configured public search engines and requires a usable result URL |

All four use the **Automation** group. The functional checks test capabilities
that process health cannot establish: browser extraction through the authenticated
route, and successful search-engine discovery. Partial engine failure is acceptable.
No exact search ranking or external page latency is asserted.

The agent's separate ServiceMonitor exposes readiness, renewal and validation
degradation, usable expiry, and fixed failure categories. Unsuspend the separate
`web-research-alerts` Flux unit with native Crawl4AI so its credential alert rules
make renewal failure observable before token expiry. Gatus availability and
missing-series rules deploy with the four endpoint definitions.

## Bootstrap and activation

The namespace, SearXNG, native Crawl4AI, dedicated proxy, and alerts Flux units start
suspended. Source validation permits this staged state without a Secret.

The operator supplies the initial SOPS-encrypted `crawl4ai-bootstrap` Secret with
`api_token` and `signing_key`. These are long-lived platform bootstrap values;
rotating data JWTs are runtime state and never require a Git commit.
The agent mounts only `api_token`; the native launcher mounts the coherent bundle.
Neither workload mounts a Kubernetes API token or writes Kubernetes Secrets.

For initial bootstrap, the operator supplies `CRAWL4AI_API_TOKEN` and
`CRAWL4AI_SIGNING_KEY` through the environment and uses the existing SOPS age
identity. Each value must contain 32–4096 printable ASCII characters. Then run:

```sh
CRAWL4AI_SECRETS_CONFIRM=write:web-research:crawl4ai:sops mise exec -- just repo crawl4ai-secrets
```

The writer encrypts both values, writes `crawl4ai/app/bootstrap.sops.yaml`, and
selects that resource in the app Kustomization. Review and commit the ciphertext
with the activation change. This bootstrap workflow is operator-run under the
repository's age-key policy; routine data-token renewal never invokes it.

The launcher watches atomic projected Secret generations without `subPath`. It
stops the old native process and all browser descendants before rendering the new
configuration on memory-backed storage and starting its replacement. An ordinary
pod replacement reconstructs this state automatically from the bootstrap bundle.

Preserve `signing_key` when rotating only `api_token`: administrative-token rotation
changes future issuance and administrative access, and does not revoke existing
data JWTs. Replacing `signing_key` revokes old-key JWTs after the native workers are
replaced. Recovery is automatic and may include a transient failed request.

Activation proceeds through Git after the initial encrypted artifact is prepared
and the specific merge is authorized. Verify the native services, rendered Gateway
policies, workload restrictions, memory bounds, credential lifecycle, actual n8n
continuity, and private LAN/Tailscale UI access before enabling the four Gatus
checks and their alert rules. Reconciliation and credential expiry must require no
manual token issuance, Secret update, consumer restart, or runtime-credential commit.

## Validation

```sh
mise exec -- just kube web-research-validate
mise exec -- just kube web-research-local-integration-test
```

The first command runs source invariants, Kustomize rendering, available Kubernetes
schemas, Prometheus rule and metric syntax, and focused runtime unit tests. The
Linux-only process-tree case also needs the pinned native Linux image.

The second command uses a running Podman machine and public internet access. It
creates disposable local containers from the pinned images, translates the current
Gateway policies, and exercises native extraction, credential rotation and recovery,
SearXNG search/UI, and all four Gatus conditions. It needs no cluster credentials or
production secrets and cleans up only the resources it creates.

Local acceptance also measured slow HTTP/1.1 and HTTP/2 consumers at the response
limit, overload rejection and recovery. Four concurrent public static-page crawls
produced native responses up to about 1 MiB and a native-container memory peak of
about 737 MiB. These ARM64 fixtures do not establish live AMD64 resource margins,
JavaScript-heavy page behavior, Cilium enforcement, n8n continuity, Kubernetes Secret
projection, or LAN/Tailscale reachability. Those remain deployment acceptance gates.

The [design record](../../../docs/specs/029-selfhost-web-research.md) contains the
acceptance requirements and evidence limits. Create the authorized career-ops
integration issue only after platform implementation and acceptance are complete.
