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
