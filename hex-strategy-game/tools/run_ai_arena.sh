#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RULES_VERSION="$(git -C "${PROJECT_DIR}/.." rev-parse HEAD 2>/dev/null || echo unknown)"

cd "${PROJECT_DIR}"
exec godot --headless --path . res://tools/ai_arena.tscn -- --rules-version="${RULES_VERSION}" "$@"
