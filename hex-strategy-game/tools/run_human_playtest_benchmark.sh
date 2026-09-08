#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
godot --headless --path . res://tools/human_playtest_benchmark.tscn -- "$@"
