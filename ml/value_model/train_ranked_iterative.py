from __future__ import annotations

"""Warm-start wrapper for iterative ranked value-model training.

The existing train_ranked entry point intentionally creates a fresh model.  Iterative
self-play needs the learner at cycle N+1 to continue from cycle N while still using
exactly the same loss, split, optimizer, checkpoint format, and metrics code.
"""

import argparse
from pathlib import Path

import torch

from . import train_ranked
from .model import HexValueNet


def split_with_parent_games(examples, args, parent_training):
    """Keep previously held-out games out of a warm-start training split."""
    if args.split_key != "game_id":
        raise ValueError("parent split preservation requires game_id grouping")
    if "training_game_ids" not in parent_training or "validation_game_ids" not in parent_training:
        raise ValueError("parent checkpoint must record both game splits")
    trained = set(parent_training["training_game_ids"])
    heldout = set(parent_training["validation_game_ids"])
    if trained & heldout:
        raise ValueError("parent game splits overlap")
    if any(not row.get("game_id") for row in examples):
        raise ValueError("all examples require a game_id")
    unseen = [row for row in examples if str(row["game_id"]) not in trained | heldout]
    seed = args.seed if args.split_seed is None else args.split_seed
    new_train, new_eval = train_ranked.split_examples_by_group(
        unseen, validation_fraction=args.validation_fraction, seed=seed, group_key="game_id")
    train = [row for row in examples if str(row["game_id"]) in trained] + new_train
    validation = [row for row in examples if str(row["game_id"]) in heldout] + new_eval
    if not train or not validation:
        raise ValueError("preserved game splits must both remain nonempty")
    return seed, train, validation


class WarmStartHexValueNet(HexValueNet):
    """HexValueNet that restores the parent value/search heads at construction."""

    init_checkpoint: str | None = None

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        path = self.init_checkpoint
        if not path:
            return

        checkpoint_path = Path(path)
        if not checkpoint_path.is_file():
            raise FileNotFoundError(f"warm-start checkpoint not found: {checkpoint_path}")

        checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
        base_state = checkpoint.get("model_state_dict")
        if not isinstance(base_state, dict):
            raise ValueError("warm-start checkpoint is missing model_state_dict")

        incompatible = self.load_state_dict(base_state, strict=False)
        unexpected = list(incompatible.unexpected_keys)
        missing = [key for key in incompatible.missing_keys if not key.startswith("policy_head.")]
        if unexpected or missing:
            raise ValueError(
                "warm-start checkpoint is incompatible with the current model: "
                f"missing={missing}, unexpected={unexpected}"
            )

        policy_state = checkpoint.get("policy_head_state_dict")
        if self.policy_head is not None and isinstance(policy_state, dict):
            self.policy_head.load_state_dict(policy_state, strict=True)


def build_parser() -> argparse.ArgumentParser:
    parser = train_ranked.build_parser()
    parser.description = (
        "Continue ranked value/search-head training from a parent checkpoint for "
        "iterative self-play experiments."
    )
    parser.add_argument(
        "--init-checkpoint",
        required=True,
        help="Parent ranked_value_model.pt used to initialize value and policy heads.",
    )
    parser.add_argument("--preserve-parent-game-split", action="store_true",
                        help="Retain the parent's held-out game IDs when adding new data.")
    parser.add_argument("--parent-ranking-data",
                        help="Parent ranking rows, to retain rank-only training game IDs.")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.preserve_parent_game_split:
        parent = torch.load(args.init_checkpoint, map_location="cpu", weights_only=False)
        parent_training = dict(parent.get("training_config", {}))
        if args.parent_ranking_data:
            pairs = train_ranked.load_ranking_pairs(args.parent_ranking_data)
            heldout = set(parent_training.get("validation_game_ids", []))
            trained = set(parent_training.get("training_game_ids", []))
            parent_training["training_game_ids"] = sorted(trained | ({str(p["game_id"]) for p in pairs} - heldout))
        args.parent_validation_game_ids = parent_training.get("validation_game_ids", [])
        train_ranked._split_examples_for_training = lambda examples, split_args, focus: split_with_parent_games(
            examples, split_args, parent_training)
    WarmStartHexValueNet.init_checkpoint = args.init_checkpoint
    # train_ranked resolves HexValueNet from its module global when train() runs,
    # so swapping only that constructor keeps all training/evaluation logic shared.
    train_ranked.HexValueNet = WarmStartHexValueNet
    train_ranked.train(args)


if __name__ == "__main__":
    main()
