"""Strict source inventory for the OpenBao 2.7 configuration contract."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar


class SafeError(Exception):
    """A fixed, printable status code; supplied exception text is discarded."""

    _CODES: ClassVar[set[str]] = {
        "invalid-source",
        "invalid-policy",
        "invalid-response",
        "incomplete-list",
        "read-denied",
        "source-mismatch",
        "timeout",
        "authentication-failed",
    }

    def __init__(self, code: str = "invalid-response"):
        super().__init__(code if code in self._CODES else "invalid-response")


@dataclass(frozen=True)
class ObjectSpec:
    kind: str
    name: str
    path: str
    fields: dict[str, object]


@dataclass(frozen=True)
class Difference:
    kind: str
    name: str | None
    field: str | None
    state: str


def _unique(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise SafeError("invalid-source")
        result[key] = value
    return result


def strict_json(value: str | bytes, code: str = "invalid-source") -> object:
    try:
        return json.loads(
            value,
            object_pairs_hook=_unique,
            parse_constant=lambda _: (_ for _ in ()).throw(SafeError(code)),
        )
    except (ValueError, TypeError, UnicodeError, SafeError) as error:
        if isinstance(error, SafeError) and str(error) == code:
            raise
        raise SafeError(code) from None


def canonical_json(value: object) -> bytes:
    try:
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False
        ).encode("ascii")
    except (TypeError, ValueError, UnicodeError):
        raise SafeError("invalid-source") from None


KINDS = {
    "auth-method",
    "secret-mount",
    "jwt-config",
    "jwt-role",
    "userpass-user",
    "policy",
    "kubernetes-config",
    "issuance-role",
}
INVENTORY_KINDS = {
    "auth-method",
    "secret-mount",
    "jwt-role",
    "userpass-user",
    "policy",
    "issuance-role",
}


def load_document(path: Path) -> dict:
    try:
        document = strict_json(path.read_bytes())
        if (
            not isinstance(document, dict)
            or set(document) != {"schema_version", "objects", "inventories", "builtin_exceptions"}
            or type(document["schema_version"]) is not int
            or document["schema_version"] != 1
        ):
            raise SafeError("invalid-source")
        if (
            not isinstance(document["objects"], list)
            or not isinstance(document["inventories"], dict)
            or not isinstance(document["builtin_exceptions"], dict)
            or set(document["inventories"]) != INVENTORY_KINDS
        ):
            raise SafeError("invalid-source")
        objects = []
        seen = set()
        for raw in document["objects"]:
            if not isinstance(raw, dict) or set(raw) not in (
                {"kind", "name", "path", "fields"},
                {"kind", "name", "path", "policy_file"},
            ):
                raise SafeError("invalid-source")
            kind, name, endpoint = raw["kind"], raw["name"], raw["path"]
            if kind not in KINDS or not all(isinstance(v, str) and v for v in (name, endpoint)):
                raise SafeError("invalid-source")
            if (kind, name) in seen:
                raise SafeError("invalid-source")
            seen.add((kind, name))
            if "policy_file" in raw:
                filename = raw["policy_file"]
                if kind != "policy" or filename not in {
                    "policies/operator.json",
                    "policies/backup.json",
                    "policies/acceptance.json",
                    "policies/config-reader.json",
                }:
                    raise SafeError("invalid-source")
                fields = {"policy": strict_json((path.parent / filename).read_bytes())}
            else:
                fields = raw["fields"]
            if not isinstance(fields, dict) or not fields:
                raise SafeError("invalid-source")
            objects.append(ObjectSpec(kind, name, endpoint, fields))
        for key, names in document["inventories"].items():
            if (
                key not in KINDS
                or not isinstance(names, list)
                or not all(isinstance(n, str) and n for n in names)
                or len(names) != len(set(names))
            ):
                raise SafeError("invalid-source")
        for key, names in document["builtin_exceptions"].items():
            if (
                key not in document["inventories"]
                or not isinstance(names, list)
                or not all(isinstance(n, str) and n for n in names)
                or len(names) != len(set(names))
            ):
                raise SafeError("invalid-source")
        for kind, names in document["inventories"].items():
            if set(names) != {obj.name for obj in objects if obj.kind == kind} or set(names) & set(
                document["builtin_exceptions"].get(kind, [])
            ):
                raise SafeError("invalid-source")
        from .drift import normalize

        for obj in objects:
            try:
                normalize(obj, obj.fields)
            except SafeError:
                raise SafeError("invalid-source") from None
        document["objects"] = tuple(objects)
        return document
    except (OSError, KeyError, ValueError, TypeError):
        raise SafeError("invalid-source") from None


def load_desired(path: Path) -> tuple[ObjectSpec, ...]:
    return load_document(path)["objects"]
