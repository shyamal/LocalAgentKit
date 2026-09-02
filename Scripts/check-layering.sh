#!/usr/bin/env bash
# Fails if LocalAgentKitCore or LocalAgentKitRuntime import an Apple framework.
# This is what keeps metric M3 ("swap the model provider without touching
# AgentCore") true over time — see PLANNING.md §2.2, CLAUDE.md, task M0-13.
set -euo pipefail

cd "$(dirname "$0")/.."

FORBIDDEN='^import (FoundationModels|CoreAI|SwiftData|Vision|Speech|EventKit|Contacts|SwiftUI)'

MATCHES="$(grep -rnE "$FORBIDDEN" Sources/LocalAgentKitCore Sources/LocalAgentKitRuntime || true)"

if [ -n "$MATCHES" ]; then
    echo "Layering violation: LocalAgentKitCore and LocalAgentKitRuntime must not import Apple frameworks." >&2
    echo "$MATCHES" >&2
    exit 1
fi

echo "Layering check passed: no forbidden imports in LocalAgentKitCore or LocalAgentKitRuntime."
