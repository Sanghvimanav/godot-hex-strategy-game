#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

RULES_VERSION="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"

godot --headless --path . res://tools/candidate_oracle_recall_screened.tscn -- \
  --preset=curated \
  --out=user://candidate_oracle_recall \
  --rules-version="${RULES_VERSION}" \
  --screening-enabled=true \
  "$@"
