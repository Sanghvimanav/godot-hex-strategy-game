#!/usr/bin/env python3
"""
Backfill estimated cost metrics for existing eval run artifacts.

Updates:
- tools/evals/runs/<run_id>/cases/*.json
- tools/evals/runs/<run_id>/summary.json
- tools/evals/leaderboard.jsonl (normalized to estimated_cost_usd_per_eval_turn)
"""

from __future__ import annotations

import json
import pathlib
from typing import Any


MODEL_PRICING_PER_MTOK_USD: dict[str, dict[str, float]] = {
    "gpt-5.4": {"input": 1.25, "output": 10.0},
    "gpt-5.4-mini": {"input": 0.25, "output": 2.0},
    "gpt-5.4-nano": {"input": 0.25, "output": 2.0},
    "gpt-5.5": {"input": 1.25, "output": 10.0},
    "gpt-5.5-mini": {"input": 0.25, "output": 2.0},
    "gpt-5": {"input": 1.25, "output": 10.0},
    "gpt-5-mini": {"input": 0.25, "output": 2.0},
    "gpt-4.1": {"input": 2.0, "output": 8.0},
    "gpt-4.1-mini": {"input": 0.4, "output": 1.6},
}


def _load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: pathlib.Path, obj: Any) -> None:
    path.write_text(json.dumps(obj, indent=2), encoding="utf-8")


def _pricing_for_model(model_name: str) -> dict[str, float]:
    return MODEL_PRICING_PER_MTOK_USD.get(model_name.strip(), {"input": 0.0, "output": 0.0})


def _estimate_usage_cost_usd(usage: dict[str, Any], model_name: str) -> float:
    if not isinstance(usage, dict):
        return 0.0
    rates = _pricing_for_model(model_name)
    input_tokens = int(usage.get("input_tokens", 0))
    output_tokens = int(usage.get("output_tokens", 0))
    return ((input_tokens / 1_000_000.0) * float(rates.get("input", 0.0))) + (
        (output_tokens / 1_000_000.0) * float(rates.get("output", 0.0))
    )


def _process_run(run_dir: pathlib.Path) -> tuple[str, float, float]:
    run_id = run_dir.name
    total_cost = 0.0
    cases_dir = run_dir / "cases"
    if cases_dir.exists():
        for case_file in sorted(cases_dir.glob("*.json")):
            try:
                case_obj = _load_json(case_file)
            except Exception:
                continue
            llm = case_obj.get("llm", {})
            if not isinstance(llm, dict):
                continue
            model_name = str(llm.get("model", ""))
            case_cost = 0.0
            usage = llm.get("usage", {})
            if isinstance(usage, dict):
                case_cost += _estimate_usage_cost_usd(usage, model_name)
            pred_usage = llm.get("prediction_usage", {})
            if isinstance(pred_usage, dict):
                case_cost += _estimate_usage_cost_usd(pred_usage, model_name)
            llm["estimated_cost_usd"] = round(case_cost, 8)
            case_obj["estimated_cost_usd"] = round(case_cost, 8)
            total_cost += case_cost
            _write_json(case_file, case_obj)

    summary_file = run_dir / "summary.json"
    cost_per_eval_turn = 0.0
    if summary_file.exists():
        try:
            summary_obj = _load_json(summary_file)
            total_eval_turns = int(summary_obj.get("total_eval_turns", summary_obj.get("total_cases", 0)))
            if total_eval_turns > 0:
                cost_per_eval_turn = total_cost / float(total_eval_turns)
            summary_obj["estimated_cost_usd"] = round(total_cost, 8)
            summary_obj["estimated_cost_usd_per_eval_turn"] = round(cost_per_eval_turn, 8)
            _write_json(summary_file, summary_obj)
        except Exception:
            pass

    return run_id, round(total_cost, 8), round(cost_per_eval_turn, 8)


def main() -> int:
    project_root = pathlib.Path(__file__).resolve().parents[2]
    runs_root = project_root / "tools" / "evals" / "runs"
    run_cost_map: dict[str, float] = {}
    run_cost_per_eval_turn_map: dict[str, float] = {}
    if runs_root.exists():
        for run_dir in sorted(runs_root.iterdir()):
            if not run_dir.is_dir():
                continue
            run_id, run_cost, run_cost_per_eval_turn = _process_run(run_dir)
            run_cost_map[run_id] = run_cost
            run_cost_per_eval_turn_map[run_id] = run_cost_per_eval_turn

    leaderboard_path = project_root / "tools" / "evals" / "leaderboard.jsonl"
    if leaderboard_path.exists():
        out_lines: list[str] = []
        for line in leaderboard_path.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            try:
                row = json.loads(s)
            except Exception:
                out_lines.append(line)
                continue
            run_id = str(row.get("run_id", ""))
            if run_id in run_cost_map:
                row["estimated_cost_usd"] = run_cost_map[run_id]
                row["estimated_cost_usd_per_eval_turn"] = run_cost_per_eval_turn_map.get(run_id, 0.0)
            out_lines.append(json.dumps(row))
        leaderboard_path.write_text("\n".join(out_lines) + ("\n" if out_lines else ""), encoding="utf-8")

    print(json.dumps({"ok": True, "runs_updated": len(run_cost_map)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

