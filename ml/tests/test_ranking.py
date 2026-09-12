from __future__ import annotations

import unittest

import torch

from ml.value_model.data import HexStateEncoder
from ml.value_model.model import HexValueNet
from ml.value_model.ranking import (
    RankingPairDataset,
    pair_as_example,
    pairwise_ranking_loss,
    ranking_accuracy,
    split_ranking_pairs_by_group_values,
)


def _state(own_q: int, enemy_q: int) -> dict:
    return {
        "scenario_id": "synthetic",
        "hex_radius": 3,
        "groups": [
            {
                "name": "terran",
                "resources": {},
                "units": [
                    {
                        "unit_id": 1,
                        "def_path": "res://src/unit/definitions/marine.tres",
                        "cell": [own_q, 0],
                        "health": 3,
                        "max_health": 3,
                        "energy": 0,
                        "max_energy": 0,
                    }
                ],
            },
            {
                "name": "zerg",
                "resources": {},
                "units": [
                    {
                        "unit_id": 2,
                        "def_path": "res://src/unit/definitions/zergling.tres",
                        "cell": [enemy_q, 0],
                        "health": 2,
                        "max_health": 2,
                        "energy": 0,
                        "max_energy": 0,
                    }
                ],
            },
        ],
        "command_hexes": {"terran": [3, 0], "zerg": [-3, 0]},
    }


def _pair(family: str = "mixed_force", weight: float = 1.0) -> dict:
    return {
        "schema_version": 1,
        "game_id": "g1",
        "turn_index": 2,
        "perspective_group": "terran",
        "opponent_group": "zerg",
        "pair_kind": "outcome",
        "weight": weight,
        "better_state": _state(1, -1),
        "worse_state": _state(2, -1),
        "better_outcome": 1.0,
        "worse_outcome": -1.0,
        "better_leaf_terminal": False,
        "worse_leaf_terminal": False,
        "source": {"base_scenario_id": family},
    }


class RankingLossTests(unittest.TestCase):
    def test_pairwise_loss_rewards_correct_order(self) -> None:
        correct = pairwise_ranking_loss(
            torch.tensor([0.8]), torch.tensor([-0.2]), torch.tensor([1.0])
        )
        reversed_loss = pairwise_ranking_loss(
            torch.tensor([-0.2]), torch.tensor([0.8]), torch.tensor([1.0])
        )
        self.assertLess(float(correct), float(reversed_loss))

    def test_ranking_accuracy_is_strict(self) -> None:
        self.assertEqual(
            ranking_accuracy(torch.tensor([1.0, 0.0]), torch.tensor([0.0, 1.0])),
            0.5,
        )

    def test_pair_dataset_encodes_both_siblings(self) -> None:
        encoder = HexStateEncoder()
        dataset = RankingPairDataset([_pair(weight=0.25)], encoder)
        better_board, better_globals, worse_board, worse_globals, weight = dataset[0]
        self.assertEqual(tuple(better_board.shape), tuple(worse_board.shape))
        self.assertEqual(tuple(better_globals.shape), tuple(worse_globals.shape))
        self.assertAlmostEqual(float(weight), 0.25)
        self.assertFalse(torch.equal(better_board, worse_board))

    def test_pair_example_preserves_leaf_terminal(self) -> None:
        pair = _pair()
        pair["better_leaf_terminal"] = True
        example = pair_as_example(pair, "better")
        self.assertTrue(example["terminal"])
        self.assertEqual(example["outcome"], 1.0)

    def test_ranking_pairs_follow_value_split_groups(self) -> None:
        pairs = [_pair("mixed_force"), _pair("attrition")]
        train, validation = split_ranking_pairs_by_group_values(
            pairs,
            "source.base_scenario_id",
            {"attrition"},
        )
        self.assertEqual(len(train), 1)
        self.assertEqual(len(validation), 1)
        self.assertEqual(train[0]["source"]["base_scenario_id"], "mixed_force")
        self.assertEqual(validation[0]["source"]["base_scenario_id"], "attrition")

    def test_policy_head_is_opt_in(self) -> None:
        encoder = HexStateEncoder()
        example = pair_as_example(_pair(), "better")
        encoded = encoder.encode(example)
        board = encoded.board.unsqueeze(0)
        globals_ = encoded.global_features.unsqueeze(0)
        model = HexValueNet()
        with self.assertRaisesRegex(RuntimeError, "policy head is not enabled"):
            model.policy_score(board, globals_)

    def test_policy_head_scores_separately_from_value_head(self) -> None:
        encoder = HexStateEncoder()
        example = pair_as_example(_pair(), "better")
        encoded = encoder.encode(example)
        board = encoded.board.unsqueeze(0)
        globals_ = encoded.global_features.unsqueeze(0)
        model = HexValueNet(policy_head=True)
        value = model(board, globals_)
        policy = model.policy_score(board, globals_)
        self.assertEqual(tuple(value.shape), (1,))
        self.assertEqual(tuple(policy.shape), (1,))
        self.assertGreaterEqual(float(value[0]), -1.0)
        self.assertLessEqual(float(value[0]), 1.0)
        self.assertGreaterEqual(float(policy[0]), -1.0)
        self.assertLessEqual(float(policy[0]), 1.0)
        self.assertIsNot(model.head, model.policy_head)


if __name__ == "__main__":
    unittest.main()
