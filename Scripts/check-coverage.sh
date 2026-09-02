#!/usr/bin/env bash
# Enforces the 80% line-coverage gate (metric M4) on LocalAgentKitCore and
# LocalAgentKitRuntime ONLY — see PLANNING.md §3.5, task M0-15. Other targets
# are not gated here.
#
# Runs the whole suite with coverage instrumentation, then restricts the
# measurement to files under Sources/LocalAgentKitCore and
# Sources/LocalAgentKitRuntime. Until real implementation lands in those
# targets there is nothing to instrument (placeholder comment-only files
# produce zero coverable lines) — in that case this exits 0 rather than
# failing on a divide-by-zero or a meaningless 0%.
set -euo pipefail

cd "$(dirname "$0")/.."

THRESHOLD="${COVERAGE_THRESHOLD:-80}"

swift test --enable-code-coverage

BIN_PATH="$(swift build --show-bin-path)"
BINARY="$BIN_PATH/LocalAgentKitPackageTests.xctest/Contents/MacOS/LocalAgentKitPackageTests"
PROFDATA="$BIN_PATH/codecov/default.profdata"

if [ ! -x "$BINARY" ] || [ ! -f "$PROFDATA" ]; then
    echo "Coverage artifacts not found (expected $BINARY / $PROFDATA)." >&2
    exit 1
fi

LCOV_FILE="$(mktemp)"
trap 'rm -f "$LCOV_FILE"' EXIT

xcrun llvm-cov export -format=lcov -instr-profile="$PROFDATA" "$BINARY" > "$LCOV_FILE"

python3 - "$LCOV_FILE" "$THRESHOLD" <<'PYEOF'
import sys

lcov_path, threshold = sys.argv[1], float(sys.argv[2])
gated_dirs = ("/Sources/LocalAgentKitCore/", "/Sources/LocalAgentKitRuntime/")

with open(lcov_path) as f:
    lines = f.read().splitlines()

hit = found = 0
in_scope = False
for line in lines:
    if line.startswith("SF:"):
        path = line[3:]
        in_scope = any(d in path for d in gated_dirs)
    elif in_scope and line.startswith("LH:"):
        hit += int(line[3:])
    elif in_scope and line.startswith("LF:"):
        found += int(line[3:])

if found == 0:
    print(
        "No coverable code in LocalAgentKitCore/LocalAgentKitRuntime yet — "
        "skipping the 80% gate (metric M4 applies once real implementation lands)."
    )
    sys.exit(0)

pct = 100.0 * hit / found
print(f"LocalAgentKitCore + LocalAgentKitRuntime line coverage: {pct:.2f}% ({hit}/{found} lines)")

if pct < threshold:
    print(f"FAIL: below the {threshold:.0f}% gate (metric M4).")
    sys.exit(1)

print(f"PASS: meets the {threshold:.0f}% gate.")
PYEOF
