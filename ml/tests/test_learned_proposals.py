import unittest
import torch
from ml.value_model.strategic_state import make_encoder
from ml.value_model.joint_plan_policy import build_vocab, ActionFeaturizer, build_search_distillation_examples
from ml.value_model.train_joint_plan_policy import split_decisions


def example():
    return {"schema_version": 1, "perspective_group": "terran", "opponent_group": "zerg", "outcome": 1,
            "state": {"hex_radius": 3, "groups": [{"name": "terran", "units": [
                {"unit_id": 1, "cell": [0, 0], "health": 3, "max_health": 5,
                 "def_path": "res://src/unit/definitions/marine.tres"}]}]}}


class LearnedProposalTests(unittest.TestCase):
    def test_effect_distinction_and_v1_compatibility(self):
        e = example(); plain = make_encoder(2).encode(e)
        e["state"]["groups"][0]["units"][0]["effects"] = [{"kind": "Stun", "duration": 2}]
        active = make_encoder(2).encode(e)
        self.assertFalse(torch.equal(plain.board, active.board))
        e["state"]["groups"][0]["units"][0]["effects"][0]["pending_first_tick"] = True
        pending = make_encoder(2).encode(e)
        self.assertFalse(torch.equal(active.board, pending.board))
        self.assertEqual(make_encoder(1).encode(e).board.shape[0], make_encoder(1).board_channels)

    def test_resource_locations_not_just_totals(self):
        e = example(); e["state"]["tile_resources"] = {"0,1": {"amount": 8}}
        a = make_encoder(2).encode(e)
        e["state"]["tile_resources"] = {"1,0": {"amount": 8}}
        self.assertFalse(torch.equal(a.board, make_encoder(2).encode(e).board))
        with self.assertRaises(ValueError): make_encoder(4)

    def test_unit_definition_vocabulary_and_hold_target(self):
        e = example(); d = {"starting_state": e["state"], "perspective_group": "terran", "opponent_group": "zerg",
            "candidates": [{"actions": [], "handwritten_worst_case_score": 1},
                {"actions": [{"unit_id": 1, "action_key": "move", "end_point": [1, 0]}], "handwritten_worst_case_score": 0}]}
        actions, units = build_vocab([d]); self.assertIn("marine", units)
        f = ActionFeaturizer(actions, units)
        self.assertEqual(f.encode(e["state"], d["candidates"][1]["actions"][0])[1], units.index("marine"))
        rows = build_search_distillation_examples(d)
        self.assertEqual(rows[0].candidate_actions[rows[0].target_index]["action_key"], "<hold>")

    def test_whole_game_split(self):
        rows = [{"game_id": f"game-{i//3}"} for i in range(12)]
        a, b = split_decisions(rows, .25, 0)
        self.assertFalse({r["game_id"] for r in a} & {r["game_id"] for r in b})
        self.assertEqual((a, b), split_decisions(rows, .25, 0))
        with self.assertRaises(ValueError): split_decisions([{}], .25, 0)


if __name__ == "__main__": unittest.main()
