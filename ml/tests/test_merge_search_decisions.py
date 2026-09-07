from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ml.value_model.merge_search_decisions import merge_search_decisions


class MergeSearchDecisionsTests(unittest.TestCase):
    def _write_shard(
        self,
        root: Path,
        name: str,
        rows: list[dict],
        *,
        complete: int | None = None,
    ) -> None:
        directory = root / name
        directory.mkdir(parents=True)
        (directory / "search_decisions.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in rows),
            encoding="utf-8",
        )
        manifest = {
            "manifest_schema_version": 1,
            "search_decision_schema_version": 1,
            "candidate_generation_contract_version": 1,
            "budget": "2x2",
            "source_trace_file": "traces.jsonl",
            "decision_file": "search_decisions.jsonl",
            "traces_considered": 1,
            "fast_traces": 1,
            "turns_considered": 1,
            "decision_count": len(rows),
            "complete_matrix_count": len(rows) if complete is None else complete,
            "incomplete_matrix_count": 0 if complete is None else len(rows) - complete,
            "failed_decision_count": 0,
            "selected_candidate_missing_count": 0,
        }
        (directory / "search_decisions_manifest.json").write_text(
            json.dumps(manifest),
            encoding="utf-8",
        )

    def test_merges_and_sorts_unique_decisions(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "shards"
            output = Path(tmp) / "merged"
            self._write_shard(
                root,
                "self-play-shard-1",
                [{"game_id": "b", "turn_index": 1, "perspective_group": "zerg"}],
            )
            self._write_shard(
                root,
                "self-play-shard-0",
                [
                    {"game_id": "a", "turn_index": 1, "perspective_group": "zerg"},
                    {"game_id": "a", "turn_index": 1, "perspective_group": "terran"},
                ],
            )

            manifest = merge_search_decisions(root, output)
            rows = [
                json.loads(line)
                for line in (output / "search_decisions.jsonl").read_text().splitlines()
                if line.strip()
            ]

            self.assertEqual(manifest["generation_shards"], 2)
            self.assertEqual(manifest["decision_count"], 3)
            self.assertEqual(manifest["complete_matrix_count"], 3)
            self.assertEqual(
                [(row["game_id"], row["perspective_group"]) for row in rows],
                [("a", "terran"), ("a", "zerg"), ("b", "zerg")],
            )

    def test_rejects_duplicate_decision_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "shards"
            row = {"game_id": "same", "turn_index": 2, "perspective_group": "terran"}
            self._write_shard(root, "self-play-shard-0", [row])
            self._write_shard(root, "self-play-shard-1", [row])
            with self.assertRaisesRegex(ValueError, "duplicate search decision"):
                merge_search_decisions(root, Path(tmp) / "merged")


if __name__ == "__main__":
    unittest.main()
