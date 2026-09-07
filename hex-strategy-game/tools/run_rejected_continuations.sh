#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

# Example with neural prioritization:
# ./tools/run_rejected_continuations.sh \
#   --out=/path/to/self_play \
#   --neural-checkpoint=/path/to/value_model.pt \
#   --max-continuations=64
#
# Without --neural-checkpoint the selector still prioritizes tactically large
# one-turn swings, which keeps CI and local smoke checks lightweight.
godot --headless --path . res://tools/search_decision_continuations.tscn -- "$@"
