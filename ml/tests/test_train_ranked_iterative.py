from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import torch

from ml.value_model.model import HexValueNet
from ml.value_model.strategic_state import make_encoder
from ml.value_model.train_ranked_iterative import WarmStartHexValueNet, split_with_parent_games


class WarmStartTrainingTests(unittest.TestCase):
    def tearDown(self) -> None:
        WarmStartHexValueNet.init_checkpoint = None

    def test_parent_game_split_is_preserved(self):
        args = SimpleNamespace(split_key="game_id", split_seed=0, seed=0, validation_fraction=.25)
        rows = [{"game_id": key} for key in ["old-train", "old-eval", "new1", "new2", "new3", "new4"]]
        parent = {"training_game_ids": ["old-train"], "validation_game_ids": ["old-eval"]}
        seed, train, validation = split_with_parent_games(rows, args, parent)
        self.assertEqual(seed, 0)
        self.assertIn(rows[0], train)
        self.assertIn(rows[1], validation)
        self.assertFalse({r["game_id"] for r in train} & {r["game_id"] for r in validation})
        self.assertEqual(len(train) + len(validation), len(rows))
        self.assertEqual((seed, train, validation), split_with_parent_games(rows, args, parent))

    def test_parent_split_fails_closed(self):
        args = SimpleNamespace(split_key="game_id", split_seed=0, seed=0, validation_fraction=.25)
        for parent in ({}, {"training_game_ids": ["x"], "validation_game_ids": ["x"]}):
            with self.assertRaises(ValueError): split_with_parent_games([], args, parent)

    def test_v2_warm_start_restores_weights(self):
        channels = make_encoder(2).board_channels
        source = HexValueNet(board_channels=channels, hidden_channels=8, residual_blocks=1, policy_head=True)
        checkpoint = {"model_state_dict": {k: v for k, v in source.state_dict().items() if not k.startswith("policy_head.")},
                      "policy_head_state_dict": source.policy_head.state_dict()}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "v2.pt"
            torch.save(checkpoint, path)
            WarmStartHexValueNet.init_checkpoint = str(path)
            restored = WarmStartHexValueNet(board_channels=channels, hidden_channels=8, residual_blocks=1, policy_head=True)
            for key, tensor in source.state_dict().items():
                self.assertTrue(torch.equal(tensor, restored.state_dict()[key]), key)

    def test_restores_value_and_policy_heads(self) -> None:
        source = HexValueNet(hidden_channels=8, residual_blocks=1, policy_head=True)
        with torch.no_grad():
            for index, parameter in enumerate(source.parameters()):
                parameter.fill_(0.01 * (index + 1))

        base_state = {
            key: value.clone()
            for key, value in source.state_dict().items()
            if not key.startswith("policy_head.")
        }
        assert source.policy_head is not None
        checkpoint = {
            "model_state_dict": base_state,
            "policy_head_state_dict": {
                key: value.clone() for key, value in source.policy_head.state_dict().items()
            },
        }

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "parent.pt"
            torch.save(checkpoint, path)
            WarmStartHexValueNet.init_checkpoint = str(path)
            restored = WarmStartHexValueNet(
                hidden_channels=8,
                residual_blocks=1,
                policy_head=True,
            )

        source_state = source.state_dict()
        restored_state = restored.state_dict()
        self.assertEqual(set(source_state), set(restored_state))
        for key in source_state:
            self.assertTrue(torch.equal(source_state[key], restored_state[key]), key)


if __name__ == "__main__":
    unittest.main()
