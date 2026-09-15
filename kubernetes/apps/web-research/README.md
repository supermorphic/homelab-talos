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
  Envoy's buffer guard can return HTTP 500 with `Internal Server Error` before Lua
  resumes; the Lua guard itself returns HTTP 502 JSON. Both are failed crawls.
- Envoy admits at most four connections, one request per connection and one HTTP/2
  stream per connection, across two workers. Its container memory limit is 256 MiB.
- The controller's `shutdown-manager` sidecar is separately limited to 64 MiB,
  making the hard ceiling across both Pod containers 320 MiB.
- The sizing budget is 32 MiB for resident responses, 128 MiB for loaded overhead,
  and 64 MiB safety margin. The deployed four-response test measured less than
  103 MiB in Envoy; its recorded high-water mark plus the generated sidecar's was
  below 167 MiB. No container restarted. The overhead allowance conservatively
  exceeds the entire measured Envoy footprint before the response allowance is added.
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

The four approved Gatus endpoints are selected in the existing Gatus endpoint array,
together with `./gatus.yaml` in `alerts/app/kustomization.yaml` for their alert rules.
[monitoring/gatus-endpoints.yaml](monitoring/gatus-endpoints.yaml) retains the shared
condition definitions used by validation and local integration. Do not use this
fragment as a Helm values replacement for the existing endpoint array.

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

Git selects the namespace, SearXNG, native Crawl4AI, dedicated proxy, and credential
alerts for initial deployment. The operator-provided encrypted bootstrap Secret is
selected with the native app. The monitoring activation change selects Gatus checks
and their alert rules together; it must merge after the remaining operator acceptance.

The operator supplies the initial SOPS-encrypted `crawl4ai-bootstrap` Secret with
`api_token` and `signing_key`. These are long-lived platform bootstrap values;
rotating data JWTs are runtime state and never require a Git commit.
The agent mounts only `api_token`; the native launcher mounts the coherent bundle.
Neither workload mounts a Kubernetes API token or writes Kubernetes Secrets.

For initial bootstrap, the operator supplies `CRAWL4AI_API_TOKEN` and
`CRAWL4AI_SIGNING_KEY` through the environment and uses the existing SOPS age
identity. Each value must contain 32–4096 printable ASCII characters. Verify the
loaded identity before running the writer; this exposes identity-check errors directly:

```sh
mise exec -- just repo secrets
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
mise exec -- just kube web-research-live-contract-test
```

The first command runs source invariants, Kustomize rendering, available Kubernetes
schemas, Prometheus rule and metric syntax, and focused runtime unit tests. The
Linux-only process-tree case also needs the pinned native Linux image.

The second command uses a running Podman machine and public internet access. It
creates disposable local containers from the pinned images, translates the current
Gateway policies, and exercises native extraction, credential rotation and recovery,
SearXNG search/UI, and all four Gatus conditions. It needs no cluster credentials or
production secrets and cleans up only the resources it creates.

The third command is a manually selected live acceptance suite. It uses
`homelab-observer` for the Deployment, ReplicaSet, Pod, owner, readiness, and rollout
preflight. It repeats that preflight, then uses `homelab-diagnostic` for one fixed
Node program sent on standard input to the current ready `n8n-main` container. The
program has no caller-supplied endpoint or executable argument. It performs bounded
search, static and JavaScript crawl, caller-header replacement, exact route exclusion,
loopback rejection, deterministic oversized-response rejection, four-request burst,
slow-consumer retention, and recovery checks. The slow-consumer phase starts exactly
four fixed raw crawls below 50 KiB, pauses every response at its headers, holds all
four for 100 milliseconds, then drains at most 8 MiB plus one sentinel and requires
four valid native JSON successes between 7 MiB and 8 MiB. Client success does not
establish the proxy's memory high-water mark; collect that evidence independently
from Prometheus. A fifth excluded-route request cannot distinguish connection
admission from normal route handling, so excess-concurrency acceptance remains
pending a reliable oracle. Output
is limited to fixed phase, result, status, size, count, and duration fields. This suite
is registered outside automatic campaigns and CI. It exercises the network position
and runtime of n8n, but it is not an n8n HTTP Request workflow execution.

Envoy's default one-second delayed-close flush can abort a one-request HTTP/1
connection when a client fully stalls it for three seconds. That behavior produced a
failed partial read in the initial deployed probe, with no OOM or container restart;
the later small burst and recovery checks passed. A partial body never satisfies this
contract as successful native JSON. The 100-millisecond hold retains all four complete
near-cap responses together without changing the production timeout for an artificial
multi-second stall.

Local acceptance also measured slow HTTP/1.1 and HTTP/2 consumers at the response
limit, overload rejection and recovery. Four concurrent public static-page crawls
produced native responses up to about 1 MiB and a native-container memory peak of
about 737 MiB. These ARM64 fixtures do not establish live AMD64 resource margins,
JavaScript-heavy page behavior, Cilium enforcement, n8n continuity, Kubernetes Secret
projection, or LAN/Tailscale reachability. Those remain deployment acceptance gates.

The [design record](../../../docs/specs/029-selfhost-web-research.md) contains the
acceptance requirements and evidence limits. Consumer integration is tracked in
[career-ops #67](https://github.com/supermorphic/career-ops/issues/67). Implementation
and tests may proceed in parallel; production cutover depends on platform acceptance.
