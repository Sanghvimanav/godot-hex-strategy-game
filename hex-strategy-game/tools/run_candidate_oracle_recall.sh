#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

RULES_VERSION="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"

# PR #70 is a broad diagnostic run. Route it through the two-stage evaluator so
# all production candidates remain in the final answer-key pass while low-priority
# oracle-only challengers are screened using the already-computed wide-search ranking.
godot --headless --path . res://tools/candidate_oracle_recall_screened.tscn -- \
  --preset=curated \
  --out=user://candidate_oracle_recall \
  --rules-version="${RULES_VERSION}" \
  --screening-enabled=true \
  --screening-top-oracle-candidates=2 \
  --screening-value-margin=0.20 \
  --screening-max-finalists=4 \
  --screening-max-turns=2 \
  --screening-own-max-plans=2 \
  --screening-opponent-max-plans=2 \
  "$@"
