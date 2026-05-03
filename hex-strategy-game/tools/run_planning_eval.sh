#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if command -v godot >/dev/null 2>&1; then
  GODOT_BIN="godot"
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
  GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"
else
  echo "error: could not find 'godot'. Install Godot or set GODOT_BIN." >&2
  exit 127
fi

cd "$PROJECT_DIR"
"$GODOT_BIN" --headless --path . res://tools/planning_eval.tscn -- "$@"
