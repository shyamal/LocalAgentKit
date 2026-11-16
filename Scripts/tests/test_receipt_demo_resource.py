"""Guard the packaged receipt fixture: host OCR tests alone cannot detect omission."""
import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReceiptDemoResourceTests(unittest.TestCase):
    def test_receipt_fixture_is_in_generated_app_resources(self):
        demo = ROOT / "Examples/LocalAgentDemo"
        png = (demo / "LocalAgentDemo/Resources/receipt-sample.png").read_bytes()
        self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II", png[16:24]), (1000, 700))
        project = (demo / "LocalAgentDemo.xcodeproj/project.pbxproj").read_text()
        phases = project.split("/* Begin PBXResourcesBuildPhase section */", 1)[1].split("/* End PBXResourcesBuildPhase section */", 1)[0]
        reference = re.search(r"([A-F0-9]{24}) /\* receipt-sample.png in Resources \*/ =", project)
        self.assertIsNotNone(reference, "Regenerate the Xcode project after adding the receipt image")
        self.assertIn(reference.group(1), phases)


if __name__ == "__main__":
    unittest.main()
