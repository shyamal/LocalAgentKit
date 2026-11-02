#!/usr/bin/env python3
"""Require documentation on source-authored public symbols in the six SDK modules.

Consumes fresh `swift package dump-symbol-graph --minimum-access-level public`
output. Synthesized declarations without a source location, imported framework
symbols, the empty AppIntents placeholder and internal evaluation targets are
outside this authored SDK API check. Nonempty comments are a coverage check,
not a substitute for reviewing their accuracy or building DocC with strict links.
"""
import argparse
import json
from pathlib import Path
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
MODULES = tuple("LocalAgentKit" + suffix for suffix in
                ("Core", "Runtime", "Providers", "Tools", "SwiftUI", "Testing"))


def audit(graph_directory, source_root=ROOT / "Sources", modules=MODULES):
    """Return module counts and diagnostics without building or modifying sources."""
    counts = {}
    problems = []
    for module in modules:
        primary = graph_directory / (module + ".symbols.json")
        if not primary.is_file():
            problems.append(f"Missing public symbol graph: {primary.name}")
            continue
        paths = [primary, *sorted(graph_directory.glob(module + "@*.symbols.json"))]
        authored = {}
        for path in paths:
            graph = json.loads(path.read_text())
            if graph.get("module", {}).get("name") != module:
                problems.append(f"Unexpected module identity in {path.name}")
                continue
            for symbol in graph["symbols"]:
                location = symbol.get("location")
                if location is None:
                    continue
                uri = urlparse(location["uri"])
                if uri.scheme != "file":
                    continue
                source = Path(unquote(uri.path))
                if not source.is_relative_to(source_root / module):
                    continue
                if symbol.get("accessLevel") not in ("public", "open"):
                    continue
                key = symbol["identifier"]["precise"]
                documented = any(line.get("text", "").strip()
                                 for line in symbol.get("docComment", {}).get("lines", []))
                previous = authored.get(key)
                if previous is None or documented:
                    authored[key] = (documented, source, location, symbol)
        counts[module] = (sum(item[0] for item in authored.values()), len(authored))
        if not authored:
            problems.append(f"No source-authored public symbols found for {module}")
        for documented, source, location, symbol in authored.values():
            if not documented:
                line = location["position"]["line"] + 1
                name = ".".join(symbol.get("pathComponents", [symbol["names"]["title"]]))
                problems.append(f"{source}:{line}: missing API documentation for {name}")
    return counts, problems


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("graph_directory", type=Path)
    args = parser.parse_args()
    counts, problems = audit(args.graph_directory)
    for module, (documented, total) in counts.items():
        print(f"{module}: {documented}/{total} authored public symbols documented")
    for problem in problems:
        print(problem)
    raise SystemExit(1 if problems else 0)
