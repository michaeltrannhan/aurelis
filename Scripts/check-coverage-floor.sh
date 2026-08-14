#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

RESULT_BUNDLE=${1:-}
FLOOR=${2:-59}

[ -n "$RESULT_BUNDLE" ] || fail "usage: $0 <result-bundle> [floor-percent]"
[ -d "$RESULT_BUNDLE" ] || fail "result bundle not found: $RESULT_BUNDLE"

REPORT=$(xcrun xccov view --report --json "$RESULT_BUNDLE" 2>/dev/null) ||
    fail "could not read coverage report from $RESULT_BUNDLE"

LINE_COVERAGE=$(
    printf '%s' "$REPORT" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
targets = data.get("targets") or []
covered = 0
executable = 0
for target in targets:
    name = target.get("name") or ""
    if name.endswith(".xctest"):
        continue
    covered += int(target.get("coveredLines") or 0)
    executable += int(target.get("executableLines") or 0)
if executable <= 0:
    print("0")
else:
    print(f"{(covered * 100.0) / executable:.2f}")
'
) || fail "could not compute line coverage percentage"

python3 - "$LINE_COVERAGE" "$FLOOR" <<'PY'
import sys
coverage = float(sys.argv[1])
floor = float(sys.argv[2])
print(f"line coverage: {coverage:.2f}% (floor {floor:.0f}%)")
if coverage + 1e-9 < floor:
    raise SystemExit(f"error: coverage {coverage:.2f}% is below floor {floor:.0f}%")
PY
