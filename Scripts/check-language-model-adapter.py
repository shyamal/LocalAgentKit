#!/usr/bin/env python3
"""Run asset-free custom LanguageModel tests on an explicit OS 27 simulator destination.

Requires Xcode 27, an installed OS 27 simulator runtime and XcodeGen. No SDK runtime
dependency is added. A temporary unit-test project references the checked-in tests;
derived data and xcresult logs remain under the output directory for inspection.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(destination, output):
    if shutil.which("xcodegen") is None:
        raise SystemExit("XcodeGen is required to generate the temporary simulator test project.")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="adapter-project-", dir=output) as temporary:
        project = Path(temporary)
        products = ("Core", "Runtime", "Providers", "Testing")
        spec = {
            "name": "AdapterCheck",
            "packages": {"LocalAgentKit": {"path": str(ROOT)}},
            "targets": {"AdapterCheck": {
                "type": "bundle.unit-test", "platform": "iOS", "deploymentTarget": "27.0",
                "sources": [{"path": str(ROOT / "Tests/LocalAgentKitProvidersTests/LanguageModelProviderTests.swift")}],
                "dependencies": [{"package": "LocalAgentKit", "product": "LocalAgentKit" + name}
                                 for name in products],
                "settings": {"base": {
                    "PRODUCT_BUNDLE_IDENTIFIER": "org.localagentkit.adaptercheck",
                    "GENERATE_INFOPLIST_FILE": "YES", "SWIFT_VERSION": "6.0",
                    "SWIFT_STRICT_CONCURRENCY": "complete", "CODE_SIGNING_ALLOWED": "NO"}},
            }},
            "schemes": {"AdapterCheck": {
                "build": {"targets": {"AdapterCheck": "all"}},
                "test": {"targets": ["AdapterCheck"]},
            }},
        }
        # JSON is valid YAML and safely quotes checkout paths containing spaces or punctuation.
        path = project / "project.yml"
        path.write_text(json.dumps(spec, indent=2))
        subprocess.run(["xcodegen", "generate", "--spec", str(path), "--project", str(project)], check=True)
        subprocess.run([
            "xcodebuild", "-project", str(project / "AdapterCheck.xcodeproj"),
            "-scheme", "AdapterCheck", "-destination", destination,
            "-derivedDataPath", str(output / "build"), "CODE_SIGNING_ALLOWED=NO", "test",
        ], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, help="An xcodebuild OS 27 simulator destination.")
    parser.add_argument("--output", type=Path, default=ROOT / ".build/language-model-adapter")
    args = parser.parse_args()
    run(args.destination, args.output.resolve())
