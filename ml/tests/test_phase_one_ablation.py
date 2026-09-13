import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_ablation", ROOT / "hex-strategy-game/tools/prepare_phase_one_ablation.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AblationTests(unittest.TestCase):
    def setUp(self):
        self.source = {"checkpoint_sha256": "hash", "rules_version": "rules",
                       "pipeline_elapsed_seconds": 136, "workers": 8,
                       "evaluation_excluded_from_training": True}

    def build(self, **kwargs):
        args = dict(source=self.source, checkpoint_sha256="hash", rules_version="rules",
                    setup_seconds=10, parent_run="34715462406")
        args.update(kwargs)
        return module.ablation_provenance(**args)

    def test_reuse_preserves_source_and_counts_setup(self):
        result = self.build()
        self.assertEqual(result["pipeline_elapsed_seconds"], 146)
        self.assertEqual(result["source_training_provenance"], self.source)
        self.assertEqual(self.source["workers"], 8)
        self.assertEqual(result["workers"], 1)
        self.assertEqual(result["new_training_epochs"], 0)

    def test_checkpoint_and_rules_must_match(self):
        for kwargs in ({"checkpoint_sha256": "wrong"}, {"rules_version": "wrong"}):
            with self.assertRaises(ValueError): self.build(**kwargs)

    def test_budget_fails_closed(self):
        for seconds in (-1, float("nan"), float("inf"), 14400 - 136):
            with self.assertRaises(ValueError): self.build(setup_seconds=seconds)

    def test_exclusion_is_required(self):
        self.source["evaluation_excluded_from_training"] = False
        with self.assertRaises(ValueError): self.build()


if __name__ == "__main__": unittest.main()
