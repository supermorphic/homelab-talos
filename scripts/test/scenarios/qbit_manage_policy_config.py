"""Strict config construction and validation for the qbit_manage policy E2E."""

from __future__ import annotations

import copy
from typing import Any, ClassVar, Protocol

import yaml


class PolicyIdentity(Protocol):
    """Run-scoped names consumed by the isolated policy builders."""

    run_id: str
    category: str
    run_tag: str
    limit_tag: str
    group: str
    cz_tag: str
    cz_limit_tag: str
    cz_public_limit_tag: str
    cz_group: str
    cz_public_group: str


class EnvReference(str):
    """A qbit_manage !ENV scalar retained by the safe YAML loader/dumper."""


class PolicyLoader(yaml.SafeLoader):
    pass


class PolicyDumper(yaml.SafeDumper):
    pass


def _construct_env(loader: PolicyLoader, node: yaml.Node) -> EnvReference:
    return EnvReference(loader.construct_scalar(node))


def _represent_env(dumper: PolicyDumper, value: EnvReference) -> yaml.Node:
    return dumper.represent_scalar("!ENV", str(value))


PolicyLoader.add_constructor("!ENV", _construct_env)
PolicyDumper.add_representer(EnvReference, _represent_env)


def load_policy_yaml(text: str) -> dict[str, Any]:
    value = yaml.load(text, Loader=PolicyLoader)
    if not isinstance(value, dict):
        raise TypeError("qbit_manage config must be a mapping")
    return value


def dump_policy_yaml(value: dict[str, Any]) -> str:
    return yaml.dump(value, Dumper=PolicyDumper, sort_keys=False)


def validate_production_isolation(config: dict[str, Any]) -> None:
    """Reject deployed policy drift that would make the live E2E unsafe."""

    commands = config.get("commands")
    settings = config.get("settings")
    share_limits = config.get("share_limits")
    if (
        not isinstance(commands, dict)
        or not isinstance(settings, dict)
        or not isinstance(share_limits, dict)
    ):
        raise TypeError("deployed production category/private isolation drifted")

    public = share_limits.get("public")
    czteam = share_limits.get("czteam")
    if not isinstance(public, dict) or not isinstance(czteam, dict):
        raise TypeError("deployed production category/private isolation drifted")

    categories = public.get("categories")
    excluded_tags = public.get("exclude_any_tags")
    czteam_tags = czteam.get("include_all_tags")
    if (
        commands.get("tag_update") is not True
        or commands.get("share_limits") is not True
        or settings.get("private_tag") != "tracker-private"
        or config.get("directory", {}).get("root_dir") != "/data/downloads"
        or not isinstance(categories, list)
        or len(categories) != 2
        or set(categories) != {"movies", "tv"}
        or not isinstance(excluded_tags, list)
        or "tracker-private" not in excluded_tags
        or "tracker-czteam" not in excluded_tags
        or public.get("priority") != 100
        or public.get("cleanup") is not True
        or not isinstance(czteam_tags, list)
        or "tracker-czteam" not in czteam_tags
        or czteam.get("priority") != 10
        or czteam.get("max_ratio") != 2.0
        or czteam.get("min_seeding_time") != "7d"
        or czteam.get("max_seeding_time") != -1
        or czteam.get("share_limit_action") != "Stop"
        or czteam.get("cleanup") is not False
    ):
        raise ValueError("deployed production category/private isolation drifted")


class PolicyConfig:
    """Build and strictly validate run-isolated accelerated policy configs."""

    TOP_KEYS: ClassVar[set[str]] = {
        "commands",
        "qbt",
        "settings",
        "directory",
        "recyclebin",
        "tracker",
        "share_limits",
    }
    COMMANDS: ClassVar[dict[str, bool]] = {
        "dry_run": False,
        "recheck": False,
        "cat_update": False,
        "tag_update": False,
        "rem_unregistered": False,
        "tag_tracker_error": False,
        "rem_orphaned": False,
        "tag_nohardlinks": False,
        "share_limits": True,
        "skip_cleanup": True,
    }

    @staticmethod
    def build(
        source: dict[str, Any],
        identity: PolicyIdentity,
        cleanup: bool,
    ) -> dict[str, Any]:
        if not isinstance(cleanup, bool):
            raise TypeError("cleanup must be a boolean")
        for key in ("qbt", "directory", "recyclebin", "tracker"):
            if not isinstance(source.get(key), dict):
                raise TypeError(f"deployed config is missing mapping {key}")
        if not source["tracker"]:
            raise ValueError("deployed config tracker mapping must not be empty")
        recyclebin = copy.deepcopy(source["recyclebin"])
        recyclebin.update({"enabled": True, "save_torrents": False})
        return {
            "commands": copy.deepcopy(PolicyConfig.COMMANDS),
            "qbt": copy.deepcopy(source["qbt"]),
            "settings": {
                "disable_qbt_default_share_limits": False,
                "share_limits_filter_completed": True,
                "share_limits_tag": f"~e2e_qbm_{identity.run_id}",
                "share_limits_min_seeding_time_tag": (f"e2e_qbm_min_seed_{identity.run_id}"),
                "share_limits_min_num_seeds_tag": (f"e2e_qbm_min_seeds_{identity.run_id}"),
                "share_limits_last_active_tag": (f"e2e_qbm_last_active_{identity.run_id}"),
            },
            "directory": copy.deepcopy(source["directory"]),
            "recyclebin": recyclebin,
            # qbit_manage v4.10.0 rejects a config when both `cat` and `tracker`
            # are empty, before it evaluates share limits. Preserve the already
            # validated deployed tracker mapping; tag_update stays false, so this
            # satisfies the parser without granting the one-shot Job authority to
            # mutate tracker classification.
            "tracker": copy.deepcopy(source["tracker"]),
            # Require both run-owned selectors. The category and tag are unique to
            # this run, while exclude_any_tags proves the tracker-private safety net.
            "share_limits": {
                identity.group: {
                    "priority": 1,
                    "categories": [identity.category],
                    "include_all_tags": [identity.run_tag],
                    "exclude_any_tags": ["tracker-private"],
                    "custom_tag": identity.limit_tag,
                    "add_group_to_tag": True,
                    "max_ratio": 0.01,
                    "min_seeding_time": "1m",
                    "max_seeding_time": "2m",
                    "share_limit_action": "Stop",
                    "cleanup": cleanup,
                }
            },
        }

    @staticmethod
    def validate(
        config: dict[str, Any],
        identity: PolicyIdentity,
        cleanup: bool,
    ) -> None:
        def require(condition: bool, reason: str) -> None:
            if not condition:
                raise ValueError(reason)

        require(set(config) == PolicyConfig.TOP_KEYS, "unexpected policy top-level keys")
        require(config.get("commands") == PolicyConfig.COMMANDS, "unsafe command authority")
        qbt = config.get("qbt", {})
        require(
            qbt.get("host") == "http://qbittorrent.media.svc.cluster.local:8080",
            "unexpected qBittorrent host",
        )
        require(
            isinstance(qbt.get("user"), EnvReference) and qbt["user"] == "QBT_USER",
            "qBittorrent user must remain !ENV QBT_USER",
        )
        require(
            isinstance(qbt.get("pass"), EnvReference) and qbt["pass"] == "QBT_PASS",
            "qBittorrent password must remain !ENV QBT_PASS",
        )
        require(
            config.get("directory", {}).get("root_dir") == "/data/downloads",
            "unexpected download root",
        )
        recyclebin = config.get("recyclebin", {})
        require(
            recyclebin.get("enabled") is True and recyclebin.get("save_torrents") is False,
            "unsafe recycle-bin settings",
        )
        trackers = config.get("tracker")
        require(isinstance(trackers, dict) and bool(trackers), "tracker mapping must not be empty")
        expected_settings = PolicyConfig.build(
            {
                "qbt": qbt,
                "directory": config["directory"],
                "recyclebin": recyclebin,
                "tracker": trackers,
            },
            identity,
            cleanup,
        )["settings"]
        require(config.get("settings") == expected_settings, "unsafe share-limit settings")
        groups = config.get("share_limits")
        require(
            isinstance(groups, dict) and set(groups) == {identity.group},
            "policy must contain exactly one run group",
        )
        expected_group = {
            "priority": 1,
            "categories": [identity.category],
            "include_all_tags": [identity.run_tag],
            "exclude_any_tags": ["tracker-private"],
            "custom_tag": identity.limit_tag,
            "add_group_to_tag": True,
            "max_ratio": 0.01,
            "min_seeding_time": "1m",
            "max_seeding_time": "2m",
            "share_limit_action": "Stop",
            "cleanup": cleanup,
        }
        require(groups[identity.group] == expected_group, "unsafe run group")

    @staticmethod
    def build_czteam_isolation(
        source: dict[str, Any],
        identity: PolicyIdentity,
    ) -> dict[str, Any]:
        config = PolicyConfig.build(source, identity, False)
        accelerated = {
            # qbit_manage v4.10.0 gates custom_tag behind add_group_to_tag.
            # With custom_tag set, True emits only that explicit run-owned tag;
            # it does not synthesize the normal priority/group tag.
            "add_group_to_tag": True,
            "max_ratio": 0.01,
            "min_seeding_time": "1m",
            "max_seeding_time": "2m",
            "share_limit_action": "Stop",
        }
        config["share_limits"] = {
            identity.cz_group: {
                "priority": 10,
                "include_all_tags": [identity.cz_tag],
                "custom_tag": identity.cz_limit_tag,
                **accelerated,
                "cleanup": False,
            },
            # This sentinel intentionally outranks CZTeam. The CZTeam analog can
            # therefore receive its policy only when the public exclusion works.
            identity.cz_public_group: {
                "priority": 1,
                "categories": [identity.category],
                "include_all_tags": [identity.run_tag],
                "exclude_any_tags": ["tracker-private", identity.cz_tag],
                "custom_tag": identity.cz_public_limit_tag,
                **accelerated,
                "cleanup": True,
            },
        }
        return config

    @staticmethod
    def validate_czteam_isolation(
        config: dict[str, Any],
        identity: PolicyIdentity,
    ) -> None:
        # Reuse the proven single-group validator for the common authority,
        # connection, directory, recycle-bin, tracker, and settings contract.
        probe = copy.deepcopy(config)
        try:
            source = {
                "qbt": config["qbt"],
                "directory": config["directory"],
                "recyclebin": config["recyclebin"],
                "tracker": config["tracker"],
            }
        except KeyError as error:
            raise ValueError("missing CZTeam policy top-level mapping") from error
        probe["share_limits"] = PolicyConfig.build(source, identity, False)["share_limits"]
        PolicyConfig.validate(probe, identity, False)

        expected = PolicyConfig.build_czteam_isolation(source, identity)["share_limits"]
        groups = config.get("share_limits")
        if not isinstance(groups, dict) or groups != expected:
            raise ValueError("unsafe CZTeam isolation groups")
