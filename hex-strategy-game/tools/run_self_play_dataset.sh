#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

RULES_VERSION="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"

# Defaults come first so caller-supplied args can override them; the Godot parser
# keeps the last value for duplicate keys.
godot --headless --path . res://tools/self_play_dataset.tscn -- \
  --preset=starter \
  --out=user://self_play_dataset \
  --rules-version="${RULES_VERSION}" \
  "$@"

# Search-decision capture is offline and does not affect the played trajectory.
# The diverse value-model dataset widens fast 2x2 turns to a 4x4 matrix so one
# decision can teach about several sibling candidates. Smoke/starter retain the
# historical 2x2 recorder unless callers explicitly override these args.
DECISION_CAPTURE_ARGS=()
for arg in "$@"; do
  if [[ "${arg}" == "--preset=diverse" ]]; then
    DECISION_CAPTURE_ARGS+=(--decision-own-max-plans=4 --decision-opponent-max-plans=4)
  fi
done

godot --headless --path . res://tools/search_decision_dataset_v2.tscn -- \
  --out=user://self_play_dataset \
  "${DECISION_CAPTURE_ARGS[@]}" \
  "$@"
