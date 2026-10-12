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
PROFDATA="$BIN_PATH/codecov/default.profdata"

# SwiftPM supports both a combined package bundle and per-target test bundles.
shopt -s nullglob
BINARIES=("$BIN_PATH"/*.xctest/Contents/MacOS/*)
if [ ${#BINARIES[@]} -eq 0 ] || [ ! -f "$PROFDATA" ]; then
    echo "Coverage artifacts not found under $BIN_PATH." >&2
    exit 1
fi
EXPORT_ARGS=("${BINARIES[0]}")
for binary in "${BINARIES[@]:1}"; do
    EXPORT_ARGS+=(-object "$binary")
done
LCOV_FILE="$(mktemp)"
trap 'rm -f "$LCOV_FILE"' EXIT
xcrun llvm-cov export -format=lcov -instr-profile="$PROFDATA" \
    "${EXPORT_ARGS[@]}" > "$LCOV_FILE"

python3 - "$LCOV_FILE" "$THRESHOLD" <<'PYEOF'
import sys

lcov_path, threshold = sys.argv[1], float(sys.argv[2])
gated_dirs = ("/Sources/LocalAgentKitCore/", "/Sources/LocalAgentKitRuntime/")

with open(lcov_path) as f:
    lines = f.read().splitlines()

# A source may occur in multiple binaries. Count each source line once and union its hits.
covered = {}
path = None
for line in lines:
    if line.startswith("SF:"):
        candidate = line[3:]
        path = candidate if any(d in candidate for d in gated_dirs) else None
    elif path and line.startswith("DA:"):
        number, count, *_ = line[3:].split(",")
        key = (path, int(number))
        covered[key] = covered.get(key, False) or int(count) > 0

hit, found = sum(covered.values()), len(covered)
for directory in gated_dirs:
    scoped = [value for (source, _), value in covered.items() if directory in source]
    if scoped:
        print(f"{directory.split('/')[-2]}: {100 * sum(scoped) / len(scoped):.2f}% "
              f"({sum(scoped)}/{len(scoped)} lines)")

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
