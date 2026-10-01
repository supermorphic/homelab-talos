# OpenBao API fixtures

`openbao-2.7-jwt-config.json` independently specifies the complete `data` response
from the pinned OpenBao 2.7.0 JWT configuration reader after installing this
repository's Kubernetes provider configuration. Field names, types and empty/new
configuration defaults were checked against
[the pinned configuration implementation](https://github.com/openbao/openbao/blob/v2.7.0/internal/builtin/credential/jwt/path_config.go).
The fixture is synthetic and contains no live response data or credentials.

The AppRole mount/role, four agent issuance roles, and agent/config-reader policy
readbacks in `openbao-2.7-read-responses.json` were captured from the official
2.7.0 Darwin arm64 release on a loopback dev server. The archive SHA-256 was
checked against the release checksums. Mount UUID/accessor values are synthetic.
No workstation enrollment or live cluster credentials were used.
