from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import torch
from torch import nn

from ml.value_model.data import (
    BOARD_CHANNELS,
    BOARD_SIZE,
    ENEMY_TYPE_OFFSET,
    GLOBAL_FEATURES,
    OWN_TYPE_OFFSET,
    UNIT_TYPE_INDEX,
    VALID_MASK_CHANNEL,
    HexStateEncoder,
    ValueExampleDataset,
    load_jsonl_examples,
    split_examples_by_game,
)
from ml.value_model.metrics import handwritten_evaluator_score, sign_accuracy
from ml.value_model.model import HexValueNet


def _unit(unit_id: int, kind: str, cell: list[int], health: int = 2, energy: int = 0) -> dict:
    return {
        "unit_id": unit_id,
        "def_path": f"res://src/unit/definitions/{kind}.tres",
        "cell": cell,
        "health": health,
        "max_health": max(health, 2),
        "energy": energy,
        "max_energy": max(energy, 0),
    }


def _example(perspective: str = "zerg", outcome: float = 1.0, game_id: str = "g1") -> dict:
    return {
        "schema_version": 1,
        "game_id": game_id,
        "turn_index": 2,
        "perspective_group": perspective,
        "opponent_group": "terran" if perspective == "zerg" else "zerg",
        "outcome": outcome,
        "terminal": False,
        "winner": "zerg",
        "state": {
            "scenario_id": "synthetic",
            "hex_radius": 1,
            "groups": [
                {"name": "zerg", "resources": {"crystal": 3}, "units": [_unit(1, "zergling", [0, 0], 2)]},
                {"name": "terran", "resources": {"people": 1}, "units": [_unit(2, "marine", [1, 0], 3)]},
            ],
            "tile_resources": {},
        },
    }


class ValueModelTests(unittest.TestCase):
    def test_hex_mask_and_perspective_channels(self) -> None:
        encoder = HexStateEncoder()
        zerg = encoder.encode(_example("zerg", 1.0))
        terran = encoder.encode(_example("terran", -1.0))
        self.assertEqual(tuple(zerg.board.shape), (BOARD_CHANNELS, BOARD_SIZE, BOARD_SIZE))
        self.assertEqual(int(zerg.board[VALID_MASK_CHANNEL].sum().item()), 7)
        center = (5, 5)
        east = (5, 6)
        zergling = UNIT_TYPE_INDEX["zergling"]
        marine = UNIT_TYPE_INDEX["marine"]
        self.assertEqual(float(zerg.board[OWN_TYPE_OFFSET + zergling, *center]), 1.0)
        self.assertEqual(float(zerg.board[ENEMY_TYPE_OFFSET + marine, *east]), 1.0)
        self.assertEqual(float(terran.board[ENEMY_TYPE_OFFSET + zergling, *center]), 1.0)
        self.assertEqual(float(terran.board[OWN_TYPE_OFFSET + marine, *east]), 1.0)
        self.assertEqual(tuple(zerg.global_features.shape), (GLOBAL_FEATURES,))

    def test_model_output_is_bounded_scalar_per_example(self) -> None:
        model = HexValueNet(hidden_channels=8, residual_blocks=1)
        board = torch.zeros((3, BOARD_CHANNELS, BOARD_SIZE, BOARD_SIZE))
        board[:, VALID_MASK_CHANNEL] = 1.0
        globals_ = torch.zeros((3, GLOBAL_FEATURES))
        result = model(board, globals_)
        self.assertEqual(tuple(result.shape), (3,))
        self.assertTrue(torch.all(result <= 1.0))
        self.assertTrue(torch.all(result >= -1.0))

    def test_split_by_game_never_leaks_perspective_pairs(self) -> None:
        examples = []
        for game in range(5):
            examples.append(_example("zerg", 1.0, f"g{game}"))
            examples.append(_example("terran", -1.0, f"g{game}"))
        train, validation = split_examples_by_game(examples, validation_fraction=0.4, seed=7)
        train_ids = {item["game_id"] for item in train}
        validation_ids = {item["game_id"] for item in validation}
        self.assertTrue(train_ids)
        self.assertTrue(validation_ids)
        self.assertTrue(train_ids.isdisjoint(validation_ids))

    def test_jsonl_loader(self) -> None:
        import json

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "examples.jsonl"
            path.write_text(json.dumps(_example()) + "\n\n", encoding="utf-8")
            loaded = load_jsonl_examples(path)
        self.assertEqual(len(loaded), 1)
        self.assertEqual(loaded[0]["game_id"], "g1")

    def test_handwritten_evaluator_parity_shape(self) -> None:
        example = _example("zerg", 1.0)
        # Terran has one extra HP, while Zerg has two extra total resources.
        self.assertEqual(handwritten_evaluator_score(example), -6.0)
        mirrored = _example("terran", -1.0)
        self.assertEqual(handwritten_evaluator_score(mirrored), 6.0)
        self.assertEqual(sign_accuracy([-6.0, 6.0], [1.0, -1.0]), 0.0)

    def test_tiny_network_can_reduce_loss(self) -> None:
        torch.manual_seed(0)
        examples = [_example("zerg", 1.0, "g1"), _example("terran", -1.0, "g1")] * 4
        dataset = ValueExampleDataset(examples)
        board = torch.stack([dataset[i][0] for i in range(len(dataset))])
        globals_ = torch.stack([dataset[i][1] for i in range(len(dataset))])
        target = torch.stack([dataset[i][2] for i in range(len(dataset))])
        model = HexValueNet(hidden_channels=8, residual_blocks=0)
        optimizer = torch.optim.Adam(model.parameters(), lr=0.02)
        loss_fn = nn.MSELoss()
        model.train()
        initial = float(loss_fn(model(board, globals_), target).item())
        for _ in range(30):
            optimizer.zero_grad(set_to_none=True)
            loss = loss_fn(model(board, globals_), target)
            loss.backward()
            optimizer.step()
        final = float(loss_fn(model(board, globals_), target).item())
        self.assertLess(final, initial * 0.5)


if __name__ == "__main__":
    unittest.main()
