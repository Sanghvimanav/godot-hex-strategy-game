from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ml.value_model.ranking import load_ranking_pairs


class RankingSchemaCompatibilityTests(unittest.TestCase):
    def _write_pair(self, schema_version: int) -> Path:
        root = Path(tempfile.mkdtemp())
        path = root / "ranking_pairs.jsonl"
        pair = {
            "schema_version": schema_version,
            "weight": 1.0,
            "better_state": {"groups": []},
            "worse_state": {"groups": []},
            "source": {"base_scenario_id": "mixed_force"},
        }
        path.write_text(json.dumps(pair) + "\n", encoding="utf-8")
        return path

    def test_loads_dense_schema_v2_pairs(self) -> None:
        pairs = load_ranking_pairs(self._write_pair(2))
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0]["schema_version"], 2)

    def test_still_loads_schema_v1_pairs(self) -> None:
        pairs = load_ranking_pairs(self._write_pair(1))
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0]["schema_version"], 1)

    def test_rejects_unknown_future_schema(self) -> None:
        with self.assertRaisesRegex(ValueError, "unsupported ranking schema_version 3"):
            load_ranking_pairs(self._write_pair(3))


if __name__ == "__main__":
    unittest.main()
