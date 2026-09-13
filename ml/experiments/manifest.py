from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
_ALLOWED_PARTITION_ROLES = {"training", "diagnostic", "frozen_eval"}


class ManifestError(ValueError):
    """Raised when an experiment manifest is invalid or unsafe."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ManifestError(message)


def _canonical_json(data: dict[str, Any]) -> str:
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def manifest_sha256(data: dict[str, Any]) -> str:
    return hashlib.sha256(_canonical_json(data).encode("utf-8")).hexdigest()


def load_manifest(path: str | Path) -> dict[str, Any]:
    manifest_path = Path(path)
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"unable to load manifest {manifest_path}: {exc}") from exc
    validate_manifest(data)
    return data


def validate_manifest(data: dict[str, Any]) -> None:
    _require(isinstance(data, dict), "manifest must be a JSON object")
    _require(data.get("schema_version") == SCHEMA_VERSION, "schema_version must be 1")

    experiment_id = data.get("experiment_id")
    _require(isinstance(experiment_id, str) and experiment_id.strip(), "experiment_id is required")

    search = data.get("search")
    _require(isinstance(search, dict), "search must be an object")
    for key in ("own_candidates", "opponent_responses", "decision_budget_seconds", "proposal_mode"):
        _require(key in search, f"search.{key} is required")
    _require(isinstance(search["own_candidates"], int) and search["own_candidates"] > 0, "search.own_candidates must be > 0")
    _require(isinstance(search["opponent_responses"], int) and search["opponent_responses"] > 0, "search.opponent_responses must be > 0")
    _require(
        isinstance(search["decision_budget_seconds"], (int, float)) and search["decision_budget_seconds"] > 0,
        "search.decision_budget_seconds must be > 0",
    )
    _require(isinstance(search["proposal_mode"], str) and search["proposal_mode"], "search.proposal_mode is required")

    partitions = data.get("seed_partitions")
    _require(isinstance(partitions, dict) and partitions, "seed_partitions must be a non-empty object")

    occupied_seeds: dict[int, str] = {}
    for name, partition in partitions.items():
        _require(isinstance(name, str) and name, "partition names must be non-empty strings")
        _require(isinstance(partition, dict), f"seed_partitions.{name} must be an object")
        role = partition.get("role")
        start = partition.get("start")
        count = partition.get("count")
        _require(role in _ALLOWED_PARTITION_ROLES, f"seed_partitions.{name}.role must be one of {sorted(_ALLOWED_PARTITION_ROLES)}")
        _require(isinstance(start, int) and start >= 0, f"seed_partitions.{name}.start must be >= 0")
        _require(isinstance(count, int) and count > 0, f"seed_partitions.{name}.count must be > 0")
        for seed in range(start, start + count):
            prior = occupied_seeds.get(seed)
            _require(prior is None, f"seed {seed} overlaps partitions {prior!r} and {name!r}")
            occupied_seeds[seed] = name

    tiers = data.get("tiers")
    _require(isinstance(tiers, dict) and tiers, "tiers must be a non-empty object")
    for tier_name, tier in tiers.items():
        _require(isinstance(tier, dict), f"tiers.{tier_name} must be an object")
        tier_partitions = tier.get("partitions")
        _require(isinstance(tier_partitions, list) and tier_partitions, f"tiers.{tier_name}.partitions must be non-empty")
        _require(len(set(tier_partitions)) == len(tier_partitions), f"tiers.{tier_name}.partitions contains duplicates")
        for partition_name in tier_partitions:
            _require(partition_name in partitions, f"tiers.{tier_name} references unknown partition {partition_name!r}")
        shards = tier.get("shards_per_partition")
        _require(isinstance(shards, int) and shards > 0, f"tiers.{tier_name}.shards_per_partition must be > 0")
        promotion_eligible = tier.get("promotion_eligible")
        _require(isinstance(promotion_eligible, bool), f"tiers.{tier_name}.promotion_eligible must be boolean")

        roles = {partitions[name]["role"] for name in tier_partitions}
        if promotion_eligible:
            _require(roles == {"frozen_eval"}, f"promotion tier {tier_name!r} may use only frozen_eval partitions")
        else:
            _require("frozen_eval" not in roles, f"non-promotion tier {tier_name!r} may not consume frozen_eval partitions")

    data_policy = data.get("data_policy", {})
    _require(isinstance(data_policy, dict), "data_policy must be an object")
    training_roles = set(data_policy.get("training_roles", ["training"]))
    mineable_roles = set(data_policy.get("mineable_roles", ["training", "diagnostic"]))
    _require("frozen_eval" not in training_roles, "frozen_eval may never be reused for training")
    _require("frozen_eval" not in mineable_roles, "frozen_eval may never be reused for mistake mining")
    _require(training_roles <= _ALLOWED_PARTITION_ROLES, "data_policy.training_roles contains an unknown role")
    _require(mineable_roles <= _ALLOWED_PARTITION_ROLES, "data_policy.mineable_roles contains an unknown role")

    gates = data.get("gates", [])
    _require(isinstance(gates, list), "gates must be a list")
    for index, gate in enumerate(gates):
        _require(isinstance(gate, dict), f"gates[{index}] must be an object")
        for key in ("name", "path", "op", "value"):
            _require(key in gate, f"gates[{index}].{key} is required")
        _require(gate["op"] in {">=", ">", "<=", "<", "=="}, f"gates[{index}].op is invalid")
        _require(isinstance(gate["value"], (int, float, bool)), f"gates[{index}].value must be numeric or boolean")


def _partition_shards(partition_name: str, partition: dict[str, Any], shard_count: int) -> list[dict[str, Any]]:
    seeds = list(range(partition["start"], partition["start"] + partition["count"]))
    buckets: list[list[int]] = [[] for _ in range(shard_count)]
    for index, seed in enumerate(seeds):
        buckets[index % shard_count].append(seed)

    shards: list[dict[str, Any]] = []
    for shard_index, shard_seeds in enumerate(buckets):
        if not shard_seeds:
            continue
        shard_id = f"{partition_name}-{shard_index:02d}"
        shards.append(
            {
                "shard_id": shard_id,
                "partition": partition_name,
                "partition_role": partition["role"],
                "shard_index": shard_index,
                "seeds": shard_seeds,
                "artifact_name": f"experiment-shard-{shard_id}",
                "result_file": f"{shard_id}.json",
            }
        )
    return shards


def build_plan(
    data: dict[str, Any],
    tier_name: str,
    *,
    rules_sha: str,
    checkpoint_sha256: str | None = None,
    completed_shards: set[str] | None = None,
) -> dict[str, Any]:
    validate_manifest(data)
    tiers = data["tiers"]
    _require(tier_name in tiers, f"unknown tier {tier_name!r}")
    _require(isinstance(rules_sha, str) and len(rules_sha) >= 7, "rules_sha must be a git SHA-like string")

    tier = tiers[tier_name]
    all_shards: list[dict[str, Any]] = []
    for partition_name in tier["partitions"]:
        all_shards.extend(
            _partition_shards(
                partition_name,
                data["seed_partitions"][partition_name],
                tier["shards_per_partition"],
            )
        )

    completed = set(completed_shards or set())
    expected_ids = {shard["shard_id"] for shard in all_shards}
    unknown_completed = completed - expected_ids
    _require(not unknown_completed, f"completed_shards contains unknown IDs: {sorted(unknown_completed)}")
    pending_shards = [shard for shard in all_shards if shard["shard_id"] not in completed]

    return {
        "schema_version": SCHEMA_VERSION,
        "experiment_id": data["experiment_id"],
        "tier": tier_name,
        "promotion_eligible": tier["promotion_eligible"],
        "manifest_sha256": manifest_sha256(data),
        "provenance": {
            "rules_sha": rules_sha,
            "checkpoint_sha256": checkpoint_sha256,
        },
        "search": data["search"],
        "data_policy": data.get(
            "data_policy",
            {"training_roles": ["training"], "mineable_roles": ["training", "diagnostic"]},
        ),
        "gates": data.get("gates", []),
        "expected_shards": all_shards,
        "completed_shard_ids": sorted(completed),
        "pending_shards": pending_shards,
    }
