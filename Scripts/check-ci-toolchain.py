#!/usr/bin/env python3
"""Require a CI host/toolchain that builds SDK 27 APIs and executes OS 27 fixture tests."""
import re
import subprocess


def version(text):
    if not re.fullmatch(r"\d+(?:\.\d+)*", text.strip()):
        raise ValueError(f"Unrecognized version: {text!r}")
    parts = tuple(map(int, text.strip().split(".")))
    return parts + (0,) * max(0, 3 - len(parts))


def validate(macos, xcode, swift, sdk):
    xcode_match = re.search(r"^Xcode (\d+(?:\.\d+)*)$", xcode, re.MULTILINE)
    swift_match = re.search(r"\bSwift version (\d+(?:\.\d+)*)", swift)
    if xcode_match is None or swift_match is None:
        return ["Could not parse Xcode/Swift version output; inspect the printed toolchain details."]
    try:
        requirements = (
            ("macOS CI host (OS 27 tests must execute)", version(macos), (27, 0, 0)),
            ("Xcode", version(xcode_match[1]), (27, 0, 0)),
            ("Swift", version(swift_match[1]), (6, 2, 0)),
            ("macOS SDK", version(sdk), (27, 0, 0)),
        )
    except ValueError as error:
        return [str(error)]
    return [f"{name} requires {'.'.join(map(str, minimum))}+; found {'.'.join(map(str, actual))}."
            for name, actual, minimum in requirements if actual < minimum]


if __name__ == "__main__":
    commands = (
        ("macOS", ["sw_vers", "-productVersion"]),
        ("Xcode", ["xcodebuild", "-version"]),
        ("Swift", ["swift", "--version"]),
        ("macOS SDK", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
    )
    outputs = []
    for name, command in commands:
        result = subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE)
        outputs.append(result.stdout.strip())
        print(f"{name}: {result.stdout.strip()}", flush=True)
    problems = validate(*outputs)
    for problem in problems:
        print(problem)
    raise SystemExit(1 if problems else 0)
