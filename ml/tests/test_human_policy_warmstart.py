import json
import tempfile
import unittest
from pathlib import Path

from ml.value_model.train_human_policy_warmstart import (
    _evaluation_only,
    discover_demo_files,
    load_demo_rows,
    split_rows,
)


def _row(game_id: str, *, split: str = ""):
    return {
        "schema_version": 1,
        "example_type": "human_policy_step",
        "game_id": game_id,
        "split": split,
        "state": {"groups": []},
        "perspective_group": "terran",
        "opponent_group": "zerg",
        "prefix_actions": [],
        "candidate_actions": [
            {"unit_id": 1, "action_key": "<hold>", "end_point": [0, 0], "path": []},
            {"unit_id": 1, "action_key": "move", "end_point": [1, 0], "path": [[1, 0]]},
        ],
        "selected_index": 1,
    }


class HumanPolicyWarmstartTests(unittest.TestCase):
    def test_discovers_session_policy_step_files_recursively(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "session-a" / "human_policy_steps.jsonl"
            second = root / "nested" / "session-b" / "human_policy_steps.jsonl"
            first.parent.mkdir(parents=True)
            second.parent.mkdir(parents=True)
            first.write_text(json.dumps(_row("a")) + "\n")
            second.write_text(json.dumps(_row("b")) + "\n")
            discovered = discover_demo_files([root])
            self.assertEqual({path.resolve() for path in discovered}, {first.resolve(), second.resolve()})

    def test_evaluation_holdout_is_never_training_data(self):
        row = _row("holdout", split="evaluation_holdout")
        self.assertTrue(_evaluation_only(row))
        row["split"] = ""
        row["source"] = {"benchmark_id": "human_playtest_v1"}
        self.assertTrue(_evaluation_only(row))

    def test_load_demo_rows_filters_holdout_and_non_autoregressive_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "human_policy_steps.jsonl"
            good = _row("train")
            holdout = _row("eval", split="evaluation_holdout")
            turn_level = {
                "example_type": "human_policy",
                "game_id": "old-format",
                "chosen_actions": [],
            }
            path.write_text(
                "\n".join(json.dumps(row) for row in (good, holdout, turn_level)) + "\n"
            )
            rows = load_demo_rows([path])
            self.assertEqual([row["game_id"] for row in rows], ["train"])

    def test_split_is_game_disjoint(self):
        rows = [_row("a"), _row("a"), _row("b"), _row("c")]
        train, heldout = split_rows(rows, validation_fraction=0.34, seed=7)
        train_ids = {row["game_id"] for row in train}
        heldout_ids = {row["game_id"] for row in heldout}
        self.assertTrue(train_ids)
        self.assertTrue(heldout_ids)
        self.assertFalse(train_ids & heldout_ids)


if __name__ == "__main__":
    unittest.main()
