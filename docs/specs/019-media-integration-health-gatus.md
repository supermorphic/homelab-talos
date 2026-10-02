# Media Integration Health with Gatus

## Intent and assurance

Reuse operated Gatus, trusted internal HTTPS routes, and Prometheus metrics for bounded
continuous media checks. A proposed custom collector offered configuration/probe failure
classification and directed-edge attribution, but maintaining adapters for uneven APIs,
a new image/workload, keys, fixtures, and native tests cost more than its reliable
coverage justified. That product was not implemented.

[Probe configuration](../../kubernetes/apps/monitoring/gatus/app/values.yaml) and
[media rules](../../kubernetes/apps/media/alerts/) own exact endpoints, cadence, selectors,
and alerts. Continuous monitoring performs only authenticated non-mutating GETs. Native
Test actions, searches, commands, requests, downloads, imports, and refreshes remain
separately authorized functional verification.

There are distinct evidence levels:

- Unauthenticated ping/status establishes route/application availability.
- Authenticated Servarr health HTTP `200` establishes credentialed API reachability only.
- Selected Seerr Sonarr/Radarr reads establish access through Seerr's saved service settings.
- Real request/import/playback establishes a stronger workflow result.

Healthy source and target endpoints do not prove their directed integration. The four
Servarr checks ignore response bodies, including malformed JSON and operational health
entries; they cannot establish native health or attribute a downstream failure. Seerr's
bounded object conditions require the selected server plus profiles and root folders,
but do not prove a later request. Seerr-to-Plex remains without continuous assurance.

## Body-condition compatibility

Servarr mixes informational update notices and operational entries in its health array.
Requiring an empty array wrongly treats ordinary updates as failures. Fixed-index checks
and whole-body patterns cannot safely distinguish arbitrary mixed arrays; changing the
release branch to make monitoring green would couple update policy to alert semantics.
A custom parser would recreate the software lifecycle this design deliberately avoided.

The corrected status-only contract accepts reduced assurance while keeping the existing
collection path. Stronger native-health interpretation requires an off-the-shelf safe
structured-array filter and an independent mixed-array oracle. Do not restore the old
empty-array condition or the never-implemented `*NativeHealthIssue` alerts.

## Credentials and trusted path

One purpose-specific encrypted Gatus Secret contains explicit source application API
keys. They remain broad upstream credentials; consumer separation does not make them
read-only. Each key is projected explicitly, never placed in URLs, conditions, metrics,
fixtures, or published errors. Detailed UI errors stay hidden.

Probes follow internal DNS, the trusted Gateway, existing HTTPRoutes, and media Services.
A failed header-forwarding or route acceptance gate requires reassessment, not silent
fallback to Service DNS, new policy, or another workload.

Under operator SOPS custody create/rotate the integration copy with the existing guarded
writer and publish through Git. Values are environment-backed and have no reloader or
Secret rollout stamp; after deployment an authorized operator replaces Gatus so it loads
new values. Keep canonical source credentials and consumer copies aligned without
copying another consumer's ciphertext.

## Validation and acceptance

Source/render checks enforce explicit key projection, trusted paths, stable metric labels,
GET-only behavior, and the status-only Servarr boundary. Independent synthetic tests
must accept HTTP `200` for empty, informational, operational, mixed, and malformed bodies
and fail non-200 responses. Alert fixtures prove holds, recovery, series isolation, and
individual missing probes. A missing series is not a failed integration.

After process replacement require three consecutive successful cycles for every Media
Integration endpoint, its Prometheus series, and inactive corresponding rules. Compare
application-native health pages and Seerr service settings independently. The general
Gatus verifier does not inspect these histories/credentials; rendering cannot prove live
credentials or downstream access. Full TV/movie request acceptance remains
[in specification 006](006-media-stack-architecture.md#application-state-recovery).

Gatus's dashboard history can disappear on restart while scraped Prometheus history
remains. The design accepts limited attribution, response drift discovered at runtime,
broad keys, one collection surface, and no end-to-end continuous transaction. A concrete
observed gap can justify reconsideration; an endpoint inventory alone cannot.
