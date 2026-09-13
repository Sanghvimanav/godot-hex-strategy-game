from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1


class ResultContractError(ValueError):
    """Raised when shard results do not satisfy the standard contract."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ResultContractError(message)


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * percentile
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return float(ordered[low])
    weight = rank - low
    return float(ordered[low] * (1.0 - weight) + ordered[high] * weight)


def _validate_counts(counts: dict[str, Any], shard_id: str) -> None:
    for key in ("wins", "losses", "draws", "unresolved", "failures"):
        value = counts.get(key)
        _require(isinstance(value, int) and value >= 0, f"{shard_id}: games.{key} must be >= 0")


def validate_shard_result(result: dict[str, Any]) -> None:
    _require(isinstance(result, dict), "shard result must be an object")
    _require(result.get("schema_version") == SCHEMA_VERSION, "shard result schema_version must be 1")
    shard_id = result.get("shard_id")
    _require(isinstance(shard_id, str) and shard_id, "shard_id is required")
    partition = result.get("partition")
    _require(isinstance(partition, str) and partition, f"{shard_id}: partition is required")

    games = result.get("games")
    _require(isinstance(games, dict), f"{shard_id}: games must be an object")
    _validate_counts(games, shard_id)

    provenance = result.get("provenance")
    _require(isinstance(provenance, dict), f"{shard_id}: provenance must be an object")
    _require(isinstance(provenance.get("rules_sha"), str), f"{shard_id}: provenance.rules_sha is required")
    checkpoint_sha = provenance.get("checkpoint_sha256")
    _require(checkpoint_sha is None or isinstance(checkpoint_sha, str), f"{shard_id}: checkpoint hash must be a string or null")

    metrics = result.get("metrics", {})
    _require(isinstance(metrics, dict), f"{shard_id}: metrics must be an object")
    for name, accumulator in metrics.items():
        _require(isinstance(accumulator, dict), f"{shard_id}: metrics.{name} must be an object")
        _require(isinstance(accumulator.get("sum"), (int, float)), f"{shard_id}: metrics.{name}.sum is required")
        _require(isinstance(accumulator.get("count"), int) and accumulator["count"] >= 0, f"{shard_id}: metrics.{name}.count must be >= 0")

    timing = result.get("timing", {})
    _require(isinstance(timing, dict), f"{shard_id}: timing must be an object")
    decision_ms = timing.get("decision_ms", [])
    _require(isinstance(decision_ms, list), f"{shard_id}: timing.decision_ms must be a list")
    for value in decision_ms:
        _require(isinstance(value, (int, float)) and value >= 0, f"{shard_id}: decision_ms values must be >= 0")
    training_seconds = timing.get("training_seconds", 0.0)
    _require(isinstance(training_seconds, (int, float)) and training_seconds >= 0, f"{shard_id}: training_seconds must be >= 0")


def load_shard_results(results_dir: str | Path) -> list[dict[str, Any]]:
    directory = Path(results_dir)
    if not directory.exists():
        return []
    results: list[dict[str, Any]] = []
    for path in sorted(directory.rglob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict) and "shard_id" in data:
            validate_shard_result(data)
            results.append(data)
    return results


def completed_shard_ids(results: Iterable[dict[str, Any]]) -> set[str]:
    ids: set[str] = set()
    for result in results:
        validate_shard_result(result)
        shard_id = result["shard_id"]
        _require(shard_id not in ids, f"duplicate shard result {shard_id!r}")
        ids.add(shard_id)
    return ids


def _empty_aggregate() -> dict[str, Any]:
    return {
        "games": {"wins": 0, "losses": 0, "draws": 0, "unresolved": 0, "failures": 0},
        "metrics": {},
        "timing": {"decision_ms": [], "training_seconds": 0.0},
    }


def _add_result(aggregate: dict[str, Any], result: dict[str, Any]) -> None:
    for key in aggregate["games"]:
        aggregate["games"][key] += result["games"][key]
    for name, accumulator in result.get("metrics", {}).items():
        target = aggregate["metrics"].setdefault(name, {"sum": 0.0, "count": 0})
        target["sum"] += float(accumulator["sum"])
        target["count"] += int(accumulator["count"])
    aggregate["timing"]["decision_ms"].extend(float(value) for value in result.get("timing", {}).get("decision_ms", []))
    aggregate["timing"]["training_seconds"] += float(result.get("timing", {}).get("training_seconds", 0.0))


def _finalize(aggregate: dict[str, Any]) -> dict[str, Any]:
    games = aggregate["games"]
    resolved = games["wins"] + games["losses"] + games["draws"]
    total = resolved + games["unresolved"]
    resolved_win_denom = resolved

    metrics: dict[str, float | None] = {}
    for name, accumulator in aggregate["metrics"].items():
        count = accumulator["count"]
        metrics[name] = accumulator["sum"] / count if count else None

    decisions = aggregate["timing"]["decision_ms"]
    return {
        "games": {
            **games,
            "resolved": resolved,
            "total": total,
            "resolution_rate": resolved / total if total else None,
            "resolved_win_rate": games["wins"] / resolved_win_denom if resolved_win_denom else None,
        },
        "metrics": metrics,
        "timing": {
            "decision_count": len(decisions),
            "decision_p50_ms": _percentile(decisions, 0.50),
            "decision_p95_ms": _percentile(decisions, 0.95),
            "decision_max_ms": max(decisions) if decisions else None,
            "training_seconds": aggregate["timing"]["training_seconds"],
        },
    }


def _lookup_path(data: dict[str, Any], path: str) -> Any:
    current: Any = data
    for part in path.split("."):
        if not isinstance(current, dict) or part not in current:
            raise KeyError(path)
        current = current[part]
    return current


def _compare(actual: Any, op: str, expected: Any) -> bool:
    if op == ">=":
        return actual >= expected
    if op == ">":
        return actual > expected
    if op == "<=":
        return actual <= expected
    if op == "<":
        return actual < expected
    if op == "==":
        return actual == expected
    raise ResultContractError(f"unsupported gate operator {op!r}")


def build_scorecard(plan: dict[str, Any], shard_results: list[dict[str, Any]]) -> dict[str, Any]:
    _require(plan.get("schema_version") == SCHEMA_VERSION, "plan schema_version must be 1")
    expected = {item["shard_id"]: item for item in plan.get("expected_shards", [])}
    _require(expected, "plan contains no expected shards")

    seen: set[str] = set()
    overall = _empty_aggregate()
    group_aggregates: dict[str, dict[str, Any]] = {}

    for result in shard_results:
        validate_shard_result(result)
        shard_id = result["shard_id"]
        _require(shard_id in expected, f"unexpected shard result {shard_id!r}")
        _require(shard_id not in seen, f"duplicate shard result {shard_id!r}")
        seen.add(shard_id)
        expected_partition = expected[shard_id]["partition"]
        _require(result["partition"] == expected_partition, f"{shard_id}: partition does not match plan")

        provenance = result["provenance"]
        _require(provenance["rules_sha"] == plan["provenance"]["rules_sha"], f"{shard_id}: rules SHA does not match plan")
        _require(
            provenance.get("checkpoint_sha256") == plan["provenance"].get("checkpoint_sha256"),
            f"{shard_id}: checkpoint hash does not match plan",
        )

        _add_result(overall, result)
        group = group_aggregates.setdefault(expected_partition, _empty_aggregate())
        _add_result(group, result)

    completed = sorted(seen)
    missing = sorted(set(expected) - seen)
    scorecard: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "experiment_id": plan["experiment_id"],
        "tier": plan["tier"],
        "promotion_eligible": bool(plan.get("promotion_eligible", False)),
        "manifest_sha256": plan.get("manifest_sha256"),
        "provenance": plan["provenance"],
        "search": plan.get("search", {}),
        "data_policy": plan.get("data_policy", {}),
        "shards": {
            "expected": len(expected),
            "completed": len(completed),
            "completed_ids": completed,
            "missing_ids": missing,
            "complete": not missing,
        },
        "overall": _finalize(overall),
        "groups": {name: _finalize(value) for name, value in sorted(group_aggregates.items())},
    }

    gate_results: list[dict[str, Any]] = [
        {
            "name": "all_shards_complete",
            "path": "shards.complete",
            "op": "==",
            "expected": True,
            "actual": not missing,
            "passed": not missing,
            "reason": None if not missing else "missing_shards",
        }
    ]
    for gate in plan.get("gates", []):
        try:
            actual = _lookup_path(scorecard, gate["path"])
            if actual is None:
                raise KeyError(gate["path"])
            passed = _compare(actual, gate["op"], gate["value"])
            reason = None if passed else "threshold_not_met"
        except KeyError:
            actual = None
            passed = False
            reason = "missing_metric"
        gate_results.append(
            {
                "name": gate["name"],
                "path": gate["path"],
                "op": gate["op"],
                "expected": gate["value"],
                "actual": actual,
                "passed": passed,
                "reason": reason,
            }
        )

    scorecard["gates"] = gate_results
    scorecard["passed"] = all(gate["passed"] for gate in gate_results)
    return scorecard
