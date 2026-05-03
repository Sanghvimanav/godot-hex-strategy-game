#!/usr/bin/env bash
# Run the headless LLM planning snapshot pipeline (no API). Writes JSON under --out (default user://llm_planning_pipeline).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"
if command -v godot >/dev/null 2>&1; then
	GODOT=godot
elif [[ -x "/Applications/Godot.app/Contents/MacOS/Godot" ]]; then
	GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
else
	echo "Godot not found. Install Godot 4 or add godot to PATH." >&2
	exit 1
fi
exec "$GODOT" --headless --path . res://tools/headless_planning_pipeline.tscn -- "$@"
