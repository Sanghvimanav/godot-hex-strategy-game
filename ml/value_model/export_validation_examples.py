from __future__ import annotations

import argparse
import json
from pathlib import Path

from .data import load_jsonl_examples, split_examples_by_group


def export_validation_examples(
    data_path: str | Path,
    output_path: str | Path,
    validation_fraction: float,
    split_key: str,
    seed: int,
) -> int:
    examples = load_jsonl_examples(data_path)
    _train, validation = split_examples_by_group(
        examples,
        validation_fraction=validation_fraction,
        seed=seed,
        group_key=split_key,
    )
    selected = [example for example in validation if not bool(example.get("terminal", False))]
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "".join(json.dumps(example, separators=(",", ":")) + "\n" for example in selected),
        encoding="utf-8",
    )
    return len(selected)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--validation-fraction", type=float, default=0.25)
    parser.add_argument("--split-key", default="source.base_scenario_id")
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()
    count = export_validation_examples(
        args.data,
        args.output,
        args.validation_fraction,
        args.split_key,
        args.seed,
    )
    print(f"exported {count} held-out nonterminal examples")


if __name__ == "__main__":
    main()
