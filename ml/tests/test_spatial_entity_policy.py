import unittest

import torch

from ml.value_model.joint_plan_policy import (
    ActionFeaturizer,
    JointPlanPolicyHead,
    SpatialEntityJointPlanPolicyHead,
    UnitEntityFeaturizer,
)
from ml.value_model.model import HexValueNet


class SpatialEntityPolicyTests(unittest.TestCase):
    def test_stacked_units_remain_distinct_entities(self):
        state = {
            "groups": [
                {
                    "name": "terran",
                    "units": [
                        {
                            "unit_id": 1,
                            "unit_type": "marine",
                            "health": 8,
                            "max_health": 10,
                            "energy": 3,
                            "max_energy": 5,
                            "cell": [0, -1],
                        },
                        {
                            "unit_id": 2,
                            "unit_type": "marine",
                            "health": 10,
                            "max_health": 10,
                            "energy": 5,
                            "max_energy": 5,
                            "cell": [0, -1],
                        },
                    ],
                },
                {
                    "name": "zerg",
                    "units": [
                        {
                            "unit_id": 3,
                            "unit_type": "zergling",
                            "health": 6,
                            "max_health": 10,
                            "cell": [0, 1],
                        }
                    ],
                },
            ]
        }
        featurizer = UnitEntityFeaturizer(["<unk>", "marine", "zergling"], max_radius=5)
        rows = featurizer.encode(state, "terran")

        self.assertEqual([row[0] for row in rows], [1, 2, 3])
        self.assertEqual(rows[0][4], (0, -1))
        self.assertEqual(rows[1][4], (0, -1))
        self.assertNotEqual(rows[0][3][0], rows[1][3][0])
        self.assertEqual(rows[0][2], 0)
        self.assertEqual(rows[2][2], 1)

    def test_encode_spatial_preserves_legacy_pooled_features(self):
        torch.manual_seed(0)
        model = HexValueNet(
            board_channels=4,
            global_features=3,
            hidden_channels=5,
            residual_blocks=1,
        )
        model.eval()
        board = torch.randn(2, 4, 5, 5)
        board[:, 0] = 0.0
        board[:, 0, 1:4, 1:4] = 1.0
        globals_ = torch.randn(2, 3)

        with torch.no_grad():
            spatial = model.body(model.stem(board))
            valid_mask = board[:, 0:1]
            expected_pooled = (spatial * valid_mask).sum(dim=(2, 3)) / valid_mask.sum(dim=(2, 3))
            expected_features = torch.cat([expected_pooled, globals_], dim=1)
            actual_spatial, actual_mask, actual_features = model.encode_spatial(board, globals_)

        self.assertTrue(torch.allclose(actual_spatial, spatial))
        self.assertTrue(torch.equal(actual_mask, valid_mask))
        self.assertTrue(torch.allclose(actual_features, expected_features))
        self.assertTrue(torch.allclose(model._features(board, globals_), expected_features))

    def test_spatial_policy_attends_over_valid_hexes_and_returns_finite_scores(self):
        torch.manual_seed(1)
        head = SpatialEntityJointPlanPolicyHead(
            state_feature_size=7,
            spatial_feature_size=4,
            action_vocab_size=3,
            unit_vocab_size=3,
            max_radius=1,
            entity_dim=8,
            spatial_hidden=8,
            attention_dim=8,
            spatial_context_dim=8,
        )
        state_features = torch.randn(1, 7)
        spatial = torch.randn(1, 4, 3, 3)
        valid_mask = torch.zeros(1, 1, 3, 3)
        for row, col in ((0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (2, 0), (2, 1)):
            valid_mask[0, 0, row, col] = 1.0

        entity_type_ids = torch.tensor([1, 1, 2], dtype=torch.long)
        entity_relation_ids = torch.tensor([0, 0, 1], dtype=torch.long)
        entity_numeric = torch.tensor(
            [[0.8, 0.6, 0.0, -1.0], [1.0, 1.0, 0.0, -1.0], [0.6, 0.0, 0.0, 1.0]],
            dtype=torch.float32,
        )
        entity_rows = torch.tensor([0, 0, 2], dtype=torch.long)
        entity_cols = torch.tensor([1, 1, 1], dtype=torch.long)
        prefix_ids = torch.empty(0, dtype=torch.long)
        prefix_unit_ids = torch.empty(0, dtype=torch.long)
        prefix_numeric = torch.empty((0, ActionFeaturizer.NUMERIC_FEATURES))
        candidate_ids = torch.tensor([1, 1], dtype=torch.long)
        candidate_unit_ids = torch.tensor([1, 1], dtype=torch.long)
        candidate_numeric = torch.tensor(
            [[0.0, -1.0, 0.0, 0.0, 0.0, 1.0, 0.0], [0.0, -1.0, 1.0, -1.0, 1.0, 0.0, 0.0]],
            dtype=torch.float32,
        )
        candidate_entities = torch.tensor([0, 1], dtype=torch.long)

        scores = head(
            state_features,
            spatial,
            valid_mask,
            entity_type_ids,
            entity_relation_ids,
            entity_numeric,
            entity_rows,
            entity_cols,
            prefix_ids,
            prefix_unit_ids,
            prefix_numeric,
            candidate_ids,
            candidate_unit_ids,
            candidate_numeric,
            candidate_entities,
        )

        self.assertEqual(tuple(scores.shape), (2,))
        self.assertTrue(torch.isfinite(scores).all())

    def test_enemy_location_changes_spatial_policy_score(self):
        torch.manual_seed(2)
        head = SpatialEntityJointPlanPolicyHead(
            state_feature_size=6,
            spatial_feature_size=3,
            action_vocab_size=3,
            unit_vocab_size=3,
            max_radius=1,
            entity_dim=8,
            spatial_hidden=8,
            attention_dim=8,
            spatial_context_dim=8,
        )
        head.eval()
        state_features = torch.zeros(1, 6)
        spatial = torch.zeros(1, 3, 3, 3)
        valid_mask = torch.ones(1, 1, 3, 3)
        entity_type_ids = torch.tensor([1, 2], dtype=torch.long)
        entity_relation_ids = torch.tensor([0, 1], dtype=torch.long)
        entity_numeric = torch.tensor(
            [[1.0, 1.0, 0.0, 0.0], [1.0, 0.0, 1.0, 0.0]], dtype=torch.float32
        )
        entity_rows = torch.tensor([1, 1], dtype=torch.long)
        prefix_ids = torch.empty(0, dtype=torch.long)
        prefix_unit_ids = torch.empty(0, dtype=torch.long)
        prefix_numeric = torch.empty((0, ActionFeaturizer.NUMERIC_FEATURES))
        candidate_ids = torch.tensor([1], dtype=torch.long)
        candidate_unit_ids = torch.tensor([1], dtype=torch.long)
        candidate_numeric = torch.tensor(
            [[0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0]], dtype=torch.float32
        )
        candidate_entities = torch.tensor([0], dtype=torch.long)

        def score(enemy_col):
            return head(
                state_features,
                spatial,
                valid_mask,
                entity_type_ids,
                entity_relation_ids,
                entity_numeric,
                entity_rows,
                torch.tensor([1, enemy_col], dtype=torch.long),
                prefix_ids,
                prefix_unit_ids,
                prefix_numeric,
                candidate_ids,
                candidate_unit_ids,
                candidate_numeric,
                candidate_entities,
            )

        with torch.no_grad():
            left = score(0)
            right = score(2)
        self.assertFalse(torch.allclose(left, right))

    def test_legacy_policy_head_remains_available(self):
        head = JointPlanPolicyHead(
            state_feature_size=7,
            action_vocab_size=3,
            unit_vocab_size=3,
        )
        state_features = torch.randn(1, 7)
        scores = head(
            state_features,
            torch.empty(0, dtype=torch.long),
            torch.empty(0, dtype=torch.long),
            torch.empty((0, ActionFeaturizer.NUMERIC_FEATURES)),
            torch.tensor([1, 2], dtype=torch.long),
            torch.tensor([1, 2], dtype=torch.long),
            torch.randn(2, ActionFeaturizer.NUMERIC_FEATURES),
        )
        self.assertEqual(tuple(scores.shape), (2,))
        self.assertTrue(torch.isfinite(scores).all())


if __name__ == "__main__":
    unittest.main()
