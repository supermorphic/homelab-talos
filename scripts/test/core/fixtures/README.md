# OpenBao API fixtures

`openbao-2.7-jwt-config.json` independently specifies the complete `data` response
from the pinned OpenBao 2.7.0 JWT configuration reader after installing this
repository's Kubernetes provider configuration. Field names, types and empty/new
configuration defaults were checked against
[the pinned configuration implementation](https://github.com/openbao/openbao/blob/v2.7.0/internal/builtin/credential/jwt/path_config.go).
The fixture is synthetic and contains no live response data or credentials.
