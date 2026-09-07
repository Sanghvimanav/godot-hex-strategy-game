"""Merge sharded 2x2 search-decision matrices for continuation labeling."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(path)
    rows: list[dict[str, Any]] = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path}:{line_number} must contain a JSON object")
        rows.append(value)
    return rows


def _decision_key(row: dict[str, Any]) -> tuple[str, int, str]:
    return (
        str(row.get("game_id", "")),
        int(row.get("turn_index", 0)),
        str(row.get("perspective_group", "")),
    )


def merge_search_decisions(root: Path, output: Path) -> dict[str, Any]:
    manifest_paths = sorted(root.glob("*/search_decisions_manifest.json"))
    if not manifest_paths and (root / "search_decisions_manifest.json").exists():
        manifest_paths = [root / "search_decisions_manifest.json"]
    if not manifest_paths:
        raise ValueError(f"no search-decision manifests found below {root}")

    rows: list[dict[str, Any]] = []
    manifests: list[dict[str, Any]] = []
    seen: set[tuple[str, int, str]] = set()
    common_fields = (
        "manifest_schema_version",
        "search_decision_schema_version",
        "candidate_generation_contract_version",
        "budget",
        "source_trace_file",
        "decision_file",
    )

    for manifest_path in manifest_paths:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ValueError(f"manifest must be an object: {manifest_path}")
        shard_rows = _read_jsonl(manifest_path.parent / "search_decisions.jsonl")
        expected = int(manifest.get("decision_count", 0))
        if len(shard_rows) != expected:
            raise ValueError(
                f"{manifest_path.parent}: decision manifest/file mismatch "
                f"({expected} != {len(shard_rows)})"
            )
        manifests.append(manifest)
        for row in shard_rows:
            key = _decision_key(row)
            if not key[0] or key[1] <= 0 or not key[2]:
                raise ValueError(f"invalid search-decision key: {key}")
            if key in seen:
                raise ValueError(f"duplicate search decision: {key}")
            seen.add(key)
            rows.append(row)

    first = manifests[0]
    for field in common_fields:
        expected = first.get(field)
        for manifest in manifests[1:]:
            if manifest.get(field) != expected:
                raise ValueError(f"inconsistent search-decision field {field!r}")

    rows.sort(key=_decision_key)
    merged = {
        "manifest_schema_version": int(first.get("manifest_schema_version", 1)),
        "search_decision_schema_version": int(first.get("search_decision_schema_version", 1)),
        "candidate_generation_contract_version": int(
            first.get("candidate_generation_contract_version", 1)
        ),
        "budget": first.get("budget", "2x2"),
        "source_trace_file": first.get("source_trace_file", "traces.jsonl"),
        "decision_file": "search_decisions.jsonl",
        "generation_shards": len(manifests),
        "traces_considered": sum(int(m.get("traces_considered", 0)) for m in manifests),
        "fast_traces": sum(int(m.get("fast_traces", 0)) for m in manifests),
        "turns_considered": sum(int(m.get("turns_considered", 0)) for m in manifests),
        "decision_count": len(rows),
        "complete_matrix_count": sum(int(m.get("complete_matrix_count", 0)) for m in manifests),
        "incomplete_matrix_count": sum(int(m.get("incomplete_matrix_count", 0)) for m in manifests),
        "failed_decision_count": sum(int(m.get("failed_decision_count", 0)) for m in manifests),
        "selected_candidate_missing_count": sum(
            int(m.get("selected_candidate_missing_count", 0)) for m in manifests
        ),
    }
    if merged["complete_matrix_count"] + merged["incomplete_matrix_count"] != len(rows):
        raise ValueError("merged search-decision completeness counts do not match rows")

    output.mkdir(parents=True, exist_ok=True)
    (output / "search_decisions.jsonl").write_text(
        "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows),
        encoding="utf-8",
    )
    (output / "search_decisions_manifest.json").write_text(
        json.dumps(merged, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return merged


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    merged = merge_search_decisions(args.root, args.output)
    print(
        "[merge-search-decisions] shards=%d decisions=%d complete=%d failed=%d"
        % (
            merged["generation_shards"],
            merged["decision_count"],
            merged["complete_matrix_count"],
            merged["failed_decision_count"],
        )
    )


if __name__ == "__main__":
    main()
