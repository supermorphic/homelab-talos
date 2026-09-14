# Gatus availability monitoring

Gatus probes the HTTP paths in `app/values.yaml` and exports results to Prometheus.
History is held in memory and resets when Gatus restarts. The
[media integration specification](../../../../docs/specs/019-media-integration-health-gatus.md)
describes the authenticated media checks and their evidence limits.

## Off-cluster management services

Separate host automation manages the off-cluster host, Caddy, DNS/TLS endpoint provisioning,
and Semaphore.
This repository owns Homepage and Gatus as consumers of trusted HTTPS URLs.
Neither monitoring service is required to operate or recover the management host.

Both Gatus checks belong to **Platform**, use unauthenticated GET every minute,
and require HTTP 200 with normal certificate and hostname verification:

| Check | URL | Evidence |
| --- | --- | --- |
| `caddy` | `https://caddy.infra.supermorphic.com/healthz` | DNS, networking, TLS, and a static response directly from Caddy |
| `semaphore` | `https://semaphore.infra.supermorphic.com/api/ping` | DNS, networking, TLS, Caddy proxying, and Semaphore's HTTP server |

The operator-selected edge URL requires deployment through the host automation.
Before merging this monitoring change, confirm the deployed URL and its reachability
from the monitoring network. Update the Gatus values, validator, and this table if
the endpoint contract changes.

| Edge | Semaphore | Interpretation |
| --- | --- | --- |
| UP | UP | Both configured HTTP paths respond |
| UP | DOWN | Investigate the Semaphore hostname, route, or application backend |
| DOWN | DOWN | Investigate the off-cluster host, DNS/networking, TLS, or Caddy first |
| DOWN | UP | Investigate the edge health hostname or route |

These checks do not prove database health, successful automation jobs, backups, or
host recovery. They use no application credentials or direct backend ports and run
no automation. They add availability results; they do not add dedicated alert rules.

The static **Platform → Semaphore** card in
[Homepage services](../homepage/app/config/services.yaml) links to the HTTPS UI and
uses the same `/api/ping` URL for `siteMonitor`. `statusStyle: basic` displays
Homepage's UP/DOWN badge; transport failures may display ERROR. This is separate
from Kubernetes workload RUNNING state. Homepage's built-in HTTP status handling is
broader than Gatus's exact HTTP 200 condition. No container integration is needed.

## Validation and activation

Run the existing source and render checks through the pinned toolchain:

```sh
mise exec -- just kube homepage-validate
mise exec -- just kube gatus-validate
```

Before publication, run the clean-candidate `mise exec -- just test ci-publish`
gate required by repository policy. Local rendering does not prove runtime DNS,
certificate trust, or HTTP reachability from Talos.

After the Caddy endpoint is deployed and Flux has reconciled this change,
verify both Platform results from Gatus and the static Homepage card. Use the
repository's scoped credentials and observational verification workflows. Confirm
the card opens the trusted Semaphore UI. Test backend-failure independence
with disposable fixtures maintained by the host automation; do not stop production
Semaphore for consumer acceptance.
