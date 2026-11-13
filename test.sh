#!/bin/zsh
# Runs the logic tests and the pointer benchmark. Needs only Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
OUT=$(mktemp -d)
CORE=(Sources/HeadMouse/MotionShaper.swift Sources/HeadMouse/DwellLogic.swift Sources/HeadMouse/HeadTracker.swift)

swiftc -O "${CORE[@]}" Tests/Logic/main.swift -o "$OUT/logic"
swiftc -O "${CORE[@]}" Tests/Benchmark/main.swift -o "$OUT/bench"

echo "== Logic tests =="
"$OUT/logic"
echo
echo "== Pointer benchmark =="
"$OUT/bench"
