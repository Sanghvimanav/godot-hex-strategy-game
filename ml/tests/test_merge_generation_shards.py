import json
import tempfile
import unittest
from pathlib import Path

from ml.value_model.merge_generation_shards import (
    merge_counterfactual,
    merge_self_play,
    shard_for_key,
    stable_hash,
)


class MergeGenerationShardsTests(unittest.TestCase):
    def test_stable_hash_matches_godot_fixture(self):
        self.assertEqual(stable_hash("game-0"), 1529306474)
        self.assertEqual(shard_for_key("game-0", 4), 2)
        self.assertEqual(shard_for_key("decision-0", 4), 2)

    def test_self_play_merge_is_complete_sorted_and_deterministic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "self_play_shards"
            output = Path(tmp) / "self_play"
            game_ids = [f"game-{i}" for i in range(12)]
            for shard_index in range(4):
                directory = root / f"self-play-shard-{shard_index}"
                directory.mkdir(parents=True)
                assigned = [game_id for game_id in game_ids if shard_for_key(game_id, 4) == shard_index]
                games = [
                    {
                        "game_id": game_id,
                        "scenario_id": "family",
                        "valid": True,
                        "labeled": True,
                    }
                    for game_id in reversed(assigned)
                ]
                examples = [
                    {
                        "game_id": game_id,
                        "turn_index": 0,
                        "perspective_group": "terran",
                        "opponent_group": "zerg",
                    }
                    for game_id in reversed(assigned)
                ]
                traces = [{"game_id": game_id} for game_id in reversed(assigned)]
                manifest = {
                    "manifest_schema_version": 1,
                    "training_example_schema_version": 1,
                    "trace_schema_version": 1,
                    "self_play_suite_version": 3,
                    "preset": "diverse",
                    "rules_version": "rules",
                    "budget_profiles": {"fast": {"own_max_plans": 2}},
                    "trace_file": "traces.jsonl",
                    "preset_jobs_considered": len(game_ids),
                    "shard_index": shard_index,
                    "shard_count": 4,
                    "shard_key": "game_id",
                    "games_requested": len(assigned),
                    "games_labeled": len(assigned),
                    "games_unlabeled": 0,
                    "games_failed": 0,
                    "example_count": len(examples),
                    "trace_count": len(traces),
                    "outcomes": {"terran": len(assigned), "zerg": 0, "draw": 0},
                    "games": games,
                }
                (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                (directory / "examples.jsonl").write_text(
                    "".join(json.dumps(row) + "\n" for row in examples), encoding="utf-8"
                )
                (directory / "traces.jsonl").write_text(
                    "".join(json.dumps(row) + "\n" for row in traces), encoding="utf-8"
                )

            merged = merge_self_play(root, output)
            self.assertEqual(merged["generation_shards"], 4)
            self.assertEqual(merged["games_requested"], len(game_ids))
            self.assertEqual(merged["example_count"], len(game_ids))
            self.assertEqual(merged["trace_count"], len(game_ids))
            self.assertEqual([game["game_id"] for game in merged["games"]], sorted(game_ids))
            lines = [json.loads(line) for line in (output / "examples.jsonl").read_text().splitlines()]
            self.assertEqual([row["game_id"] for row in lines], sorted(game_ids))

    def test_counterfactual_merge_keeps_each_decision_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "counterfactual_shards"
            output = Path(tmp) / "counterfactual"
            decision_ids = [f"decision-{i}" for i in range(8)]
            for shard_index in range(4):
                directory = root / f"counterfactual-shard-{shard_index}"
                directory.mkdir(parents=True)
                assigned = [
                    decision_id
                    for decision_id in decision_ids
                    if shard_for_key(decision_id, 4) == shard_index
                ]
                decisions = [
                    {"decision_id": decision_id, "valid": True, "candidate_count": 2}
                    for decision_id in reversed(assigned)
                ]
                candidates = []
                for decision_id in reversed(assigned):
                    candidates.extend(
                        [
                            {"decision_id": decision_id, "candidate_id": "b"},
                            {"decision_id": decision_id, "candidate_id": "a"},
                        ]
                    )
                manifest = {
                    "manifest_schema_version": 1,
                    "candidate_schema_version": 1,
                    "counterfactual_benchmark_version": 1,
                    "counterfactual_suite_version": 1,
                    "preset": "curated",
                    "rules_version": "rules",
                    "target_semantics": "policy_conditional_terminal_return_estimate",
                    "uncertainty_semantics": "descriptive",
                    "opponent_mixture_version": "opp-v1",
                    "continuation_mixture_version": "cont-v1",
                    "turn_limit_is_unlabeled": True,
                    "preset_decisions_considered": len(decision_ids),
                    "shard_index": shard_index,
                    "shard_count": 4,
                    "shard_key": "decision_id",
                    "decisions_requested": len(assigned),
                    "decisions_failed": 0,
                    "candidate_count": len(candidates),
                    "fully_labeled_candidates": len(candidates),
                    "partially_labeled_candidates": 0,
                    "unlabeled_candidates": 0,
                    "decisions": decisions,
                }
                (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                (directory / "candidates.jsonl").write_text(
                    "".join(json.dumps(row) + "\n" for row in candidates), encoding="utf-8"
                )

            merged = merge_counterfactual(root, output)
            self.assertEqual(merged["generation_shards"], 4)
            self.assertEqual(merged["decisions_requested"], len(decision_ids))
            self.assertEqual(merged["candidate_count"], len(decision_ids) * 2)
            self.assertEqual(
                [decision["decision_id"] for decision in merged["decisions"]], sorted(decision_ids)
            )
            rows = [json.loads(line) for line in (output / "candidates.jsonl").read_text().splitlines()]
            self.assertEqual(
                [(row["decision_id"], row["candidate_id"]) for row in rows],
                sorted((decision_id, candidate_id) for decision_id in decision_ids for candidate_id in ("a", "b")),
            )


if __name__ == "__main__":
    unittest.main()
