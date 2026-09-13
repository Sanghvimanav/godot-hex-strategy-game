from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _fmt(value: Any, digits: int = 3) -> str:
    if value is None:
        return "—"
    if isinstance(value, (int, float)):
        return f"{float(value):.{digits}f}"
    return str(value)


def aggregate(root: Path) -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for metrics_path in sorted(root.rglob("metrics.json")):
        metrics = _load(metrics_path)
        if "training_fraction" not in metrics or "cnn" not in metrics or "pretrained" not in metrics:
            continue
        run_dir = metrics_path.parent
        cnn_cf_path = run_dir / "cnn_counterfactual_metrics.json"
        pretrained_cf_path = run_dir / "pretrained_counterfactual_metrics.json"
        cnn_cf = _load(cnn_cf_path) if cnn_cf_path.exists() else None
        pretrained_cf = _load(pretrained_cf_path) if pretrained_cf_path.exists() else None
        rows.append(
            {
                "training_fraction": float(metrics["training_fraction"]),
                "training_examples": int(metrics["training_examples"]),
                "training_ranking_pairs": int(metrics["training_ranking_pairs"]),
                "cnn": metrics["cnn"],
                "pretrained": metrics["pretrained"],
                "cnn_counterfactual": (
                    cnn_cf.get("evaluators", {}).get("neural_value_model") if cnn_cf else None
                ),
                "pretrained_counterfactual": (
                    pretrained_cf.get("evaluators", {}).get("pretrained_value_model") if pretrained_cf else None
                ),
            }
        )
    rows.sort(key=lambda row: row["training_fraction"])
    if not rows:
        raise ValueError(f"no experiment metrics found under {root}")

    full_cnn = next((row for row in reversed(rows) if row["training_fraction"] >= 0.999), None)
    sample_efficiency = None
    if full_cnn is not None:
        baseline_rank = float(full_cnn["cnn"]["validation_ranking"]["accuracy"])
        for row in rows:
            if float(row["pretrained"]["validation_ranking"]["accuracy"]) >= baseline_rank:
                sample_efficiency = {
                    "metric": "validation_ranking_accuracy",
                    "cnn_full_data": baseline_rank,
                    "pretrained_first_matching_fraction": row["training_fraction"],
                }
                break
    return {"experiment_version": 1, "rows": rows, "sample_efficiency": sample_efficiency}


def markdown(result: dict[str, Any]) -> str:
    lines = [
        "# Pretrained value-transfer experiment",
        "",
        "Same frozen validation families, same terminal-value + sibling-ranking objective, same counterfactual candidates.",
        "",
        "| Train data | Examples | Pairs | CNN held-out rank | Pretrained held-out rank | CNN sign | Pretrained sign | CNN CF rank | Pretrained CF rank | CNN CF regret | Pretrained CF regret | CNN train s | Pretrained train s |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in result["rows"]:
        cnn_cf = row.get("cnn_counterfactual") or {}
        pre_cf = row.get("pretrained_counterfactual") or {}
        lines.append(
            "| "
            + " | ".join(
                [
                    f"{row['training_fraction']:.0%}",
                    str(row["training_examples"]),
                    str(row["training_ranking_pairs"]),
                    _fmt(row["cnn"]["validation_ranking"]["accuracy"]),
                    _fmt(row["pretrained"]["validation_ranking"]["accuracy"]),
                    _fmt(row["cnn"]["validation_value"]["sign_accuracy"]),
                    _fmt(row["pretrained"]["validation_value"]["sign_accuracy"]),
                    _fmt(cnn_cf.get("candidate_ranking_accuracy")),
                    _fmt(pre_cf.get("candidate_ranking_accuracy")),
                    _fmt(cnn_cf.get("top_plan_mean_regret")),
                    _fmt(pre_cf.get("top_plan_mean_regret")),
                    _fmt(row["cnn"]["train_seconds"], 1),
                    _fmt(row["pretrained"]["train_seconds"], 1),
                ]
            )
            + " |"
        )
    lines.append("")
    if result.get("sample_efficiency"):
        item = result["sample_efficiency"]
        lines.append(
            f"Pretrained model first matches/exceeds the 100% CNN held-out ranking accuracy at **{item['pretrained_first_matching_fraction']:.0%}** of training data."
        )
    else:
        lines.append(
            "A full-data CNN reference was not available, or the pretrained model did not match it in the completed fractions."
        )
    lines.extend(
        [
            "",
            "Candidate Oracle Recall is intentionally not part of this scorecard because candidate generation is unchanged; this experiment tests value/ranking quality after a candidate has been generated.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate pretrained value-transfer fraction runs.")
    parser.add_argument("--root", required=True)
    parser.add_argument("--json-output", required=True)
    parser.add_argument("--markdown-output", required=True)
    args = parser.parse_args()
    result = aggregate(Path(args.root))
    json_output = Path(args.json_output)
    markdown_output = Path(args.markdown_output)
    json_output.parent.mkdir(parents=True, exist_ok=True)
    markdown_output.parent.mkdir(parents=True, exist_ok=True)
    json_output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_output.write_text(markdown(result), encoding="utf-8")
    print(markdown(result))


if __name__ == "__main__":
    main()
