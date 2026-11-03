#!/usr/bin/env python3
"""Verify deployed DocC module routes and render data over HTTP."""
import argparse
import json
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

MODULES = ("Core", "Runtime", "Providers", "Tools", "SwiftUI", "Testing")
MAX_BYTES = 5 * 1024 * 1024


def fetch(url):
    request = Request(url, headers={"User-Agent": "LocalAgentKit-docs-check"})
    with urlopen(request, timeout=15) as response:
        if response.status != 200:
            raise ValueError(f"Expected HTTP 200: {url} ({response.status})")
        data = response.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError(f"Response exceeds {MAX_BYTES} bytes: {url}")
    return data


def check(base_url, read=fetch):
    parsed = urlsplit(base_url)
    if (parsed.scheme not in ("http", "https") or not parsed.netloc
            or parsed.query or parsed.fragment or parsed.username or parsed.password):
        raise ValueError("Supply an HTTP(S) site URL without credentials, query or fragment.")
    base = base_url.rstrip("/") + "/"
    checked = []
    for name in ("LocalAgentKit",) + tuple("LocalAgentKit" + area for area in MODULES):
        route = "documentation/" if name == "LocalAgentKit" else "documentation/" + name.lower() + "/"
        url = base + route
        html = read(url).decode("utf-8").lower()
        if "<html" not in html:
            raise ValueError(f"Missing HTML page: {url}")
        data_route = "data/documentation.json" if name == "LocalAgentKit" else "data/" + route.rstrip("/") + ".json"
        data_url = base + data_route
        node = json.loads(read(data_url))
        if node.get("metadata", {}).get("title") != name:
            raise ValueError(f"Wrong DocC title at {data_url}: expected {name}")
        checked.extend((url, data_url))
    return checked


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="Published site root, including any project prefix")
    args = parser.parse_args()
    try:
        routes = check(args.url)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Published documentation check failed: {error}\n")
    print(f"Published documentation passed: {len(routes)} routes across package and six modules.")
