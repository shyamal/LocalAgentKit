#!/usr/bin/env bash
# M1-TS-05: run the full default suite with socket networking denied on macOS.
# Build first so compilation and dependency resolution are outside this runtime check.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -x /usr/bin/sandbox-exec ]; then
  echo "This verification requires macOS sandbox-exec." >&2
  exit 1
fi
# Keep profiles from a coverage-instrumented build out of the checkout.
PROFILE_DIR="$(mktemp -d)"
trap 'rm -rf "$PROFILE_DIR"' EXIT
# SwiftPM cannot nest its manifest sandbox inside sandbox-exec; disable that inner sandbox.
# The outer network-denial policy remains active.
# Clear the opt-in even if the caller normally enables real-model integration tests.
# The deny applies to the test process and children, not pre-existing system services.
/usr/bin/sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  /usr/bin/env -u LOCALAGENTKIT_DEVICE_TESTS LLVM_PROFILE_FILE="$PROFILE_DIR/%p.profraw" swift test --disable-sandbox --skip-build
