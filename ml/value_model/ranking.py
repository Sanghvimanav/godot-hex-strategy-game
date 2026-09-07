from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Sequence

import torch
from torch import nn
from torch.utils.data import Dataset

from .data import HexStateEncoder

RANKING_SCHEMA_VERSION = 1


def load_ranking_pairs(path: str | Path) -> list[dict[str, Any]]:
    pairs: list[dict[str, Any]] = []
    with Path(path).open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.strip()
            if not line:
                continue
            value = json.loads(line)
            if not isinstance(value, dict):
                raise ValueError(f"line {line_number} is not a JSON object")
            if int(value.get("schema_version", -1)) != RANKING_SCHEMA_VERSION:
                raise ValueError(
                    f"line {line_number} has unsupported ranking schema_version "
                    f"{value.get('schema_version')}"
                )
            if not isinstance(value.get("better_state"), dict) or not isinstance(
                value.get("worse_state"), dict
            ):
                raise ValueError(f"line {line_number} is missing better/worse state")
            weight = float(value.get("weight", 0.0))
            if weight <= 0.0:
                raise ValueError(f"line {line_number} has non-positive weight")
            pairs.append(value)
    return pairs


def ranking_group_value(pair: dict[str, Any], group_key: str) -> str:
    if not group_key:
        raise ValueError("group_key is required")
    value: Any = pair
    for part in group_key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise ValueError(f"ranking pair is missing split key '{group_key}'")
        value = value[part]
    result = str(value)
    if not result:
        raise ValueError(f"ranking pair split key '{group_key}' is empty")
    return result


def split_ranking_pairs_by_group_values(
    pairs: Sequence[dict[str, Any]],
    group_key: str,
    validation_group_values: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    train: list[dict[str, Any]] = []
    validation: list[dict[str, Any]] = []
    for pair in pairs:
        group_value = ranking_group_value(pair, group_key)
        (validation if group_value in validation_group_values else train).append(pair)
    return train, validation


def pair_as_example(pair: dict[str, Any], side: str) -> dict[str, Any]:
    if side not in {"better", "worse"}:
        raise ValueError("side must be 'better' or 'worse'")
    state = pair.get(f"{side}_state")
    if not isinstance(state, dict):
        raise ValueError(f"ranking pair is missing {side}_state")
    return {
        "schema_version": 1,
        "perspective_group": str(pair.get("perspective_group", "")),
        "opponent_group": str(pair.get("opponent_group", "")),
        "state": state,
        "turn_index": int(pair.get("turn_index", 0)),
        "terminal": bool(pair.get(f"{side}_leaf_terminal", False)),
        "outcome": float(pair.get(f"{side}_outcome", 0.0)),
    }


class RankingPairDataset(
    Dataset[
        tuple[
            torch.Tensor,
            torch.Tensor,
            torch.Tensor,
            torch.Tensor,
            torch.Tensor,
        ]
    ]
):
    def __init__(
        self,
        pairs: Sequence[dict[str, Any]],
        encoder: HexStateEncoder | None = None,
    ):
        self.pairs = list(pairs)
        self.encoder = encoder or HexStateEncoder()

    def __len__(self) -> int:
        return len(self.pairs)

    def __getitem__(
        self, index: int
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        pair = self.pairs[index]
        better = self.encoder.encode(pair_as_example(pair, "better"))
        worse = self.encoder.encode(pair_as_example(pair, "worse"))
        weight = torch.tensor(float(pair.get("weight", 1.0)), dtype=torch.float32)
        return (
            better.board,
            better.global_features,
            worse.board,
            worse.global_features,
            weight,
        )


def pairwise_ranking_loss(
    better_scores: torch.Tensor,
    worse_scores: torch.Tensor,
    weights: torch.Tensor | None = None,
) -> torch.Tensor:
    """Logistic pairwise loss: penalize V(better) <= V(worse)."""
    if better_scores.shape != worse_scores.shape:
        raise ValueError("better_scores and worse_scores must have the same shape")
    losses = nn.functional.softplus(-(better_scores - worse_scores))
    if weights is None:
        return losses.mean()
    if weights.shape != losses.shape:
        raise ValueError("weights must match score shape")
    denominator = weights.sum().clamp_min(torch.finfo(weights.dtype).eps)
    return (losses * weights).sum() / denominator


def ranking_accuracy(
    better_scores: torch.Tensor,
    worse_scores: torch.Tensor,
) -> float:
    if better_scores.numel() == 0:
        return float("nan")
    if better_scores.shape != worse_scores.shape:
        raise ValueError("better_scores and worse_scores must have the same shape")
    return float((better_scores > worse_scores).float().mean().item())


def ranking_kind_counts(pairs: Sequence[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for pair in pairs:
        kind = str(pair.get("pair_kind", "unknown"))
        counts[kind] = counts.get(kind, 0) + 1
    return counts
