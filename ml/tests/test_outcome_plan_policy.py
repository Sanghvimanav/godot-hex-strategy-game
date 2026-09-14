import unittest

from ml.value_model.joint_plan_policy import action_signature
from ml.value_model.train_outcome_plan_policy import (
    _perspective_reward,
    _trajectory_id,
    build_outcome_examples,
)


class OutcomePlanPolicyTests(unittest.TestCase):
    def _decision(self):
        state = {
            "turn_index": 0,
            "groups": [
                {
                    "name": "terran",
                    "units": [
                        {
                            "unit_id": 1,
                            "health": 3,
                            "max_health": 3,
                            "cell": [0, 0],
                            "def_path": "marine.tres",
                            "effects": [],
                        }
                    ],
                },
                {
                    "name": "zerg",
                    "units": [
                        {
                            "unit_id": 2,
                            "health": 2,
                            "max_health": 2,
                            "cell": [1, 0],
                            "def_path": "zergling.tres",
                            "effects": [],
                        }
                    ],
                },
            ],
        }
        attack = {"unit_id": 1, "action_key": "attack", "end_point": [1, 0], "path": []}
        move = {"unit_id": 1, "action_key": "move", "end_point": [-1, 0], "path": [[-1, 0]]}
        return {
            "valid": True,
            "game_id": "tiny-neural-greedy-terran",
            "perspective_group": "terran",
            "opponent_group": "zerg",
            "starting_state": state,
            "selected_candidate_index": 1,
            "candidates": [
                {"candidate_index": 0, "actions": [attack], "selected": False, "handwritten_worst_case_score": 999.0},
                {"candidate_index": 1, "actions": [move], "selected": True, "handwritten_worst_case_score": -999.0},
            ],
        }

    def test_trajectory_id_strips_perspective_suffix(self):
        self.assertEqual(_trajectory_id(self._decision()), "tiny-neural-greedy")

    def test_perspective_reward(self):
        self.assertEqual(_perspective_reward("terran", "terran", "zerg"), 1.0)
        self.assertEqual(_perspective_reward("zerg", "terran", "zerg"), -1.0)
        self.assertEqual(_perspective_reward("", "terran", "zerg"), 0.0)

    def test_selected_self_play_plan_is_target_even_when_search_score_disagrees(self):
        examples = build_outcome_examples(self._decision())
        self.assertEqual(len(examples), 1)
        example = examples[0]
        chosen = example.candidate_actions[example.target_index]
        self.assertEqual(chosen["action_key"], "move")
        self.assertIn("move", action_signature(chosen))


if __name__ == "__main__":
    unittest.main()
