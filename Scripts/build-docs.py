#!/usr/bin/env python3
"""Build and merge strict DocC archives from the package's public symbol graphs."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

MODULES = tuple("LocalAgentKit" + suffix for suffix in
                ("Core", "Runtime", "Providers", "Tools", "SwiftUI", "Testing"))
ROOT = Path(__file__).resolve().parents[1]


def build(output, base_path):
    result = subprocess.run(["swift", "package", "dump-symbol-graph", "--minimum-access-level", "public"],
                            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="", flush=True)
    result.check_returncode()
    matches = re.findall(r"^Files written to (.+)$", result.stdout, re.MULTILINE)
    if not matches:
        raise RuntimeError("Swift did not report its symbol graph directory.")
    source = Path(matches[-1])
    subprocess.run(["python3", str(ROOT / "Scripts/check-api-docs.py"), str(source)],
                   cwd=ROOT, check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".localagentkit-docc-", dir=output.parent) as temporary:
        work = Path(temporary)
        archives = []
        for module in MODULES:
            graphs = work / (module + "-graphs")
            graphs.mkdir()
            for path in source.glob("*.symbols.json"):
                if path.name == module + ".symbols.json" or path.name.startswith(module + "@"):
                    shutil.copyfile(path, graphs / path.name)
            if not (graphs / (module + ".symbols.json")).is_file():
                raise RuntimeError(f"Missing public symbol graph for {module}.")
            archive = work / (module + ".doccarchive")
            command = ["xcrun", "docc", "convert", str(ROOT / "Documentation" / (module + ".docc")),
                       "--additional-symbol-graph-dir", str(graphs), "--output-path", str(archive),
                       "--fallback-bundle-identifier", "org.localagentkit." + module.lower(),
                       "--hosting-base-path", base_path, "--warnings-as-errors",
                       "--enable-experimental-external-link-support"]
            for dependency in archives:
                command += ["--dependency", str(dependency)]
            subprocess.run(command, cwd=ROOT, check=True)
            archives.append(archive)
        merged = work / "LocalAgentKit.doccarchive"
        subprocess.run(["xcrun", "docc", "merge", *map(str, archives), "--output-path", str(merged),
                        "--synthesized-landing-page-name", "LocalAgentKit"], check=True, cwd=ROOT)
        previous = None
        if output.exists():
            metadata = json.loads((output / "metadata.json").read_text())
            landing = json.loads((output / "data/documentation.json").read_text())
            if (metadata.get("bundleID") != "org.localagentkit.localagentkitcore"
                    or landing.get("metadata", {}).get("title") != "LocalAgentKit"):
                raise ValueError("Refusing to replace an archive not owned by this documentation build.")
            previous = work / "previous.doccarchive"
            output.rename(previous)
        try:
            merged.rename(output)
        except BaseException:
            if previous is not None:
                previous.rename(output)
            raise
    print(f"Documentation archive: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".build/documentation/LocalAgentKit.doccarchive")
    parser.add_argument("--hosting-base-path", default="/LocalAgentKit")
    args = parser.parse_args()
    build(args.output.resolve(), args.hosting_base_path)
