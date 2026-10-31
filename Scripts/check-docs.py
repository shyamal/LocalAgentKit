#!/usr/bin/env python3
"""Check that merged DocC pages and their internal topic links have static routes."""
import argparse
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit


def check(archive):
    landing = json.loads((archive / "data/documentation.json").read_text())
    if landing["metadata"]["title"] != "LocalAgentKit":
        raise ValueError("Missing merged package landing page.")
    modules = ["core", "runtime", "providers", "tools", "swiftui", "testing"]
    for module in modules:
        if not (archive / "documentation" / ("localagentkit" + module) / "index.html").is_file():
            raise ValueError(f"Missing module route: {module}")
    checked = 0
    for path in (archive / "data").rglob("*.json"):
        node = json.loads(path.read_text())
        for reference in node.get("references", {}).values():
            url = reference.get("url", "")
            if not url.startswith("/documentation"):
                continue
            route = unquote(urlsplit(url).path).strip("/")
            if not (archive / route / "index.html").is_file():
                raise ValueError(f"Broken static topic link in {path.name}: {url}")
            checked += 1
    print(f"DocC static routes passed: six module pages, {checked} internal topic references.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    check(parser.parse_args().archive)
