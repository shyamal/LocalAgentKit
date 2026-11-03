"""Published-site validation fixtures require no network or model assets."""
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location(
    "published_docs", Path(__file__).resolve().parents[1] / "check-published-docs.py")
DOCS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCS)


class PublishedDocsTests(unittest.TestCase):
    def setUp(self):
        self.base = "https://example.test/LocalAgentKit/"
        self.pages = {}
        for name in ("LocalAgentKit",) + tuple("LocalAgentKit" + area for area in DOCS.MODULES):
            route = "documentation/" if name == "LocalAgentKit" else "documentation/" + name.lower() + "/"
            self.pages[self.base + route] = b"<!doctype html><html><body>DocC</body></html>"
            data = "data/documentation.json" if name == "LocalAgentKit" else "data/" + route.rstrip("/") + ".json"
            self.pages[self.base + data] = json.dumps({"metadata": {"title": name}}).encode()

    def test_all_routes_include_project_prefix(self):
        routes = DOCS.check(self.base.rstrip("/"), self.pages.__getitem__)
        self.assertEqual(len(routes), 14)
        self.assertEqual(set(routes), set(self.pages))

    def test_domain_root_is_supported(self):
        root_pages = {key.replace("/LocalAgentKit/", "/"): value for key, value in self.pages.items()}
        self.assertEqual(len(DOCS.check("https://example.test/", root_pages.__getitem__)), 14)

    def test_missing_module_fails(self):
        def missing(url):
            if url.endswith("localagentkittools/"):
                raise OSError("HTTP 404")
            return self.pages[url]
        with self.assertRaises(OSError):
            DOCS.check(self.base, missing)

    def test_html_error_page_instead_of_json_fails(self):
        self.pages[self.base + "data/documentation/localagentkitcore.json"] = b"<html>Not found</html>"
        with self.assertRaises(ValueError):
            DOCS.check(self.base, self.pages.__getitem__)

    def test_wrong_module_data_fails(self):
        self.pages[self.base + "data/documentation/localagentkitcore.json"] = b'{"metadata":{"title":"Other"}}'
        with self.assertRaisesRegex(ValueError, "Wrong DocC title"):
            DOCS.check(self.base, self.pages.__getitem__)

    def test_non_html_route_fails(self):
        self.pages[self.base + "documentation/"] = b"not HTML"
        with self.assertRaisesRegex(ValueError, "Missing HTML"):
            DOCS.check(self.base, self.pages.__getitem__)

    def test_invalid_urls_fail_before_fetch(self):
        for url in ("file:///tmp/docs", "https://example.test/?x=1", "https://example.test/#x", "https://user:pass@example.test"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                DOCS.check(url, lambda _: self.fail("Unexpected fetch"))


if __name__ == "__main__":
    unittest.main()
