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

# Search-decision data is a post-process so the played game and normal search
# pruning are untouched. The recorder defaults to the historical fast 2x2 matrix,
# while value-model experiments can widen only this offline capture to 4x4 so each
# played decision exposes more sibling candidates without changing gameplay search.
godot --headless --path . res://tools/search_decision_dataset_v2.tscn -- \
  --out=user://self_play_dataset \
  "$@"
