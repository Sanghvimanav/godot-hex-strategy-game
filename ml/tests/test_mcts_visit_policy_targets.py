import unittest

from ml.value_model.joint_plan_policy import action_signature, build_mcts_visit_examples


class MCTSVisitPolicyTargetTests(unittest.TestCase):
    def test_visit_mass_decomposes_into_autoregressive_prefix_targets(self):
        state = {
            "turn_index": 0,
            "groups": [
                {
                    "name": "terran",
                    "units": [
                        {"unit_id": 1, "health": 10, "cell": [0, 0], "unit_type": "marine", "effects": []},
                        {"unit_id": 2, "health": 10, "cell": [0, 1], "unit_type": "marine", "effects": []},
                    ],
                },
                {"name": "zerg", "units": [{"unit_id": 3, "health": 10, "cell": [1, 0], "unit_type": "zergling", "effects": []}]},
            ],
        }

        def action(unit_id, target):
            return {"unit_id": unit_id, "action_key": "attack_short", "end_point": target, "path": []}

        u1_left = action(1, [-1, 0])
        u1_right = action(1, [1, 0])
        u2_left = action(2, [-1, 0])
        u2_right = action(2, [1, 0])
        decision = {
            "starting_state": state,
            "perspective_group": "terran",
            "opponent_group": "zerg",
            "mcts_visit_distribution": [
                {"actions": [u1_left, u2_right], "visits": 70},
                {"actions": [u1_left, u2_left], "visits": 20},
                {"actions": [u1_right, u2_left], "visits": 10},
            ],
        }

        examples = build_mcts_visit_examples(decision)
        self.assertEqual(len(examples), 2)

        root = next(example for example in examples if not example.prefix_actions)
        root_targets = {
            action_signature(action): probability
            for action, probability in zip(root.candidate_actions, root.target_distribution)
        }
        self.assertAlmostEqual(root_targets[action_signature(u1_left)], 0.9)
        self.assertAlmostEqual(root_targets[action_signature(u1_right)], 0.1)

        after_left = next(example for example in examples if len(example.prefix_actions) == 1)
        self.assertEqual(action_signature(after_left.prefix_actions[0]), action_signature(u1_left))
        second_targets = {
            action_signature(action): probability
            for action, probability in zip(after_left.candidate_actions, after_left.target_distribution)
        }
        self.assertAlmostEqual(second_targets[action_signature(u2_right)], 70.0 / 90.0)
        self.assertAlmostEqual(second_targets[action_signature(u2_left)], 20.0 / 90.0)


if __name__ == "__main__":
    unittest.main()
