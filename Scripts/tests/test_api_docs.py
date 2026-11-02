"""Exercise the API comment gate with small symbol graphs, without Swift or a model."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "api_docs", Path(__file__).resolve().parents[1] / "check-api-docs.py")
API = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(API)


class APIDocumentationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source_root = self.directory / "Sources"
        self.module = "LocalAgentKitCore"

    def symbol(self, documented=True):
        value = {
            "identifier": {"precise": "s:test"}, "accessLevel": "public",
            "names": {"title": "sample()"}, "pathComponents": ["sample()"],
            "location": {
                "uri": (self.source_root / self.module / "API.swift").as_uri(),
                "position": {"line": 4, "character": 0}},
        }
        if documented:
            value["docComment"] = {"lines": [{"text": "Produces a sample result."}]}
        return value

    def write(self, symbols, suffix="", identity=None):
        path = self.directory / (self.module + suffix + ".symbols.json")
        path.write_text(json.dumps({
            "module": {"name": identity or self.module}, "symbols": symbols}))

    def audit(self):
        return API.audit(self.directory, self.source_root, (self.module,))

    def test_documented_authored_symbol_passes(self):
        self.write([self.symbol()])
        self.assertEqual(self.audit(), ({self.module: (1, 1)}, []))

    def test_missing_comment_reports_source_and_line(self):
        self.write([self.symbol(False)])
        counts, problems = self.audit()
        self.assertEqual(counts[self.module], (0, 1))
        self.assertIn("API.swift:5: missing API documentation for sample()", problems[0])

    def test_whitespace_comment_is_missing(self):
        symbol = self.symbol()
        symbol["docComment"]["lines"][0]["text"] = "  "
        self.write([symbol])
        self.assertTrue(self.audit()[1])

    def test_generated_imported_and_internal_symbols_are_excluded(self):
        generated = self.symbol(False)
        del generated["location"]
        imported = self.symbol(False)
        imported["location"]["uri"] = (self.source_root / "SwiftUI" / "View.swift").as_uri()
        internal = self.symbol(False)
        internal["accessLevel"] = "internal"
        self.write([self.symbol(), generated, imported, internal])
        self.assertEqual(self.audit(), ({self.module: (1, 1)}, []))

    def test_extension_symbols_are_checked_and_duplicate_ids_deduplicated(self):
        self.write([self.symbol()])
        extension = self.symbol(False)
        extension["identifier"]["precise"] = "s:extension"
        self.write([self.symbol(), extension], "@Foundation")
        counts, problems = self.audit()
        self.assertEqual(counts[self.module], (1, 2))
        self.assertEqual(len(problems), 1)

    def test_missing_empty_or_wrong_module_graph_does_not_pass(self):
        self.assertTrue(self.audit()[1])
        self.write([])
        self.assertTrue(self.audit()[1])
        self.write([self.symbol()], identity="OtherModule")
        self.assertTrue(self.audit()[1])


if __name__ == "__main__":
    unittest.main()
