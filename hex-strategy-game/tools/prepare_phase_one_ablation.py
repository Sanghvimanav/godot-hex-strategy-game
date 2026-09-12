"""Reuse an unchanged candidate for a proposal ablation, with honest provenance."""
import argparse
import hashlib
import json
import math
from pathlib import Path


def ablation_provenance(source, checkpoint_sha256, rules_version, setup_seconds, parent_run):
    if source.get("checkpoint_sha256") != checkpoint_sha256:
        raise ValueError("reused checkpoint hash mismatch")
    if source.get("rules_version") != rules_version:
        raise ValueError("ablation must use the candidate's frozen rules")
    if source.get("evaluation_excluded_from_training") is not True:
        raise ValueError("training exclusion provenance is required")
    original = source.get("pipeline_elapsed_seconds")
    if not isinstance(original, (int, float)) or not math.isfinite(original) or original < 0:
        raise ValueError("valid original training elapsed time is required")
    if not math.isfinite(setup_seconds) or setup_seconds < 0 or original + setup_seconds >= 14400:
        raise ValueError("four-hour pipeline budget exceeded")
    return {**source, "pipeline_elapsed_seconds": original + setup_seconds,
            "reused_pipeline_elapsed_seconds": original,
            "ablation_setup_elapsed_seconds": setup_seconds,
            "workers": 1, "generation_workers": 0, "model_training_workers": 0,
            "capture_download_workers": 1, "parent_run": str(parent_run),
            "source_training_provenance": source,
            "experiment": "same-checkpoint-handwritten-proposals-only",
            "new_training_examples": 0, "new_training_epochs": 0}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument("--rules-version", required=True)
    parser.add_argument("--parent-run", required=True)
    parser.add_argument("--setup-seconds", type=float, required=True)
    args = parser.parse_args()
    source = json.loads(args.provenance.read_text())
    digest = hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()
    result = ablation_provenance(source, digest, args.rules_version, args.setup_seconds, args.parent_run)
    args.provenance.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
