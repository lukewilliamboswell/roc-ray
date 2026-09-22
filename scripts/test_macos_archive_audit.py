from pathlib import Path
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audit_macos_archives import APPLICATION_CALLBACKS, parse_symbols, verify_closure


class MacOSArchiveAuditTests(unittest.TestCase):
    def test_preserves_members_and_symbol_strength(self):
        refs, definitions, kinds = parse_symbols(
            "host.a[first.o]: _external U 0 0\n"
            "host.a[second.o]: _optional w 0 0\n"
            "host.a[first.o]: _provided T 0 0\n", Path("host.a"))
        self.assertEqual(refs["_external"], {"first.o"})
        self.assertEqual(refs["_optional"], {"second.o"})
        self.assertEqual(definitions, {"_provided"})
        self.assertEqual(kinds, {"T": 1, "U": 1, "w": 1})

    def test_unknown_records_fail(self):
        with self.assertRaisesRegex(ValueError, "unrecognized"):
            parse_symbols("unexpected heading", Path("host.a"))

    def test_closure_classifies_callbacks_and_objc_selector_stubs(self):
        externals = ["_system_api", "_objc_msgSend$setTitle:", *APPLICATION_CALLBACKS]
        report = {"external_symbols": [
            {"name": name, "references": [{"archive": 0, "member": "host.o"}]}
            for name in externals
        ]}
        catalog = {"libraries": [{"symbols": [
            {"name": "_system_api"}, {"name": "_objc_msgSend"},
        ]}]}
        result = verify_closure(report, catalog)
        self.assertEqual(result["classification"]["uncovered_external_symbols"], [])
        self.assertEqual(len(result["classification"]["application_callbacks"]), 6)

    def test_closure_rejects_an_unreviewed_external(self):
        externals = ["_surprise", *APPLICATION_CALLBACKS]
        report = {"external_symbols": [{"name": name, "references": []} for name in externals]}
        with self.assertRaisesRegex(ValueError, "_surprise"):
            verify_closure(report, {"libraries": [{"symbols": []}]})


if __name__ == "__main__":
    unittest.main()
