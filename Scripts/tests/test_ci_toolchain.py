import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "ci_toolchain", Path(__file__).resolve().parents[1] / "check-ci-toolchain.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class CIToolchainTests(unittest.TestCase):
    def check(self, macos="27.0.1", xcode="Xcode 27.1\nBuild version 27A9275",
              swift="Apple Swift version 6.4.1 effective-5.10", sdk="27.0"):
        return CHECK.validate(macos, xcode, swift, sdk)

    def test_documented_host_and_toolchain_pass(self):
        self.assertEqual(self.check(), [])

    def test_new_sdk_on_older_host_cannot_silently_skip_os27_tests(self):
        problems = self.check(macos="26.6.2")
        self.assertEqual(len(problems), 1)
        self.assertIn("OS 27 tests must execute", problems[0])

    def test_old_xcode_or_sdk_is_rejected(self):
        self.assertTrue(self.check(xcode="Xcode 26.6\nBuild version example"))
        self.assertTrue(self.check(sdk="26.4"))

    def test_swift_62_minimum_and_new_major_versions(self):
        self.assertEqual(self.check(swift="Swift version 6.2"), [])
        self.assertTrue(self.check(swift="Swift version 6.1.9"))
        self.assertEqual(self.check(swift="Swift version 7.0"), [])

    def test_malformed_output_cannot_pass(self):
        for override in ({"xcode": "unavailable"}, {"swift": "unavailable"},
                         {"macos": "unknown"}, {"sdk": "27.invalid"}):
            with self.subTest(override=override):
                self.assertTrue(self.check(**override))


if __name__ == "__main__":
    unittest.main()
