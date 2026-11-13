from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LayeringTests(unittest.TestCase):
    def run_check(self, imports):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Scripts').mkdir()
            shutil.copyfile(ROOT / 'Scripts/check-layering.sh', root / 'Scripts/check-layering.sh')
            for target in ['LocalAgentKitCore', 'LocalAgentKitRuntime', 'LocalAgentKitTools']:
                path = root / 'Sources' / target
                path.mkdir(parents=True)
                (path / 'Example.swift').write_text(imports.get(target, 'import Foundation\n'))
            return subprocess.run(['bash', str(root / 'Scripts/check-layering.sh')],
                                  capture_output=True, text=True)

    def test_pdfkit_import_is_rejected_in_each_gated_target(self):
        for target in ['LocalAgentKitCore', 'LocalAgentKitRuntime']:
            with self.subTest(target=target):
                result = self.run_check({target: 'import PDFKit\n'})
                self.assertEqual(result.returncode, 1)
                self.assertIn('Layering violation', result.stderr)
                self.assertIn(target, result.stderr)

    def test_audio_frameworks_are_rejected_in_each_gated_target(self):
        for framework in ['AVFoundation', 'AVFAudio']:
            for target in ['LocalAgentKitCore', 'LocalAgentKitRuntime']:
                with self.subTest(framework=framework, target=target):
                    result = self.run_check({target: f'import {framework}\n'})
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('Layering violation', result.stderr)

    def test_pdfkit_in_tools_and_foundation_in_core_are_allowed(self):
        result = self.run_check({'LocalAgentKitTools': 'import PDFKit\n',
                                 'LocalAgentKitCore': 'import Foundation\n// import PDFKit\n'})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Layering check passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
