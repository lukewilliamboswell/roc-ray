from pathlib import Path
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audit_macos_archives import parse_symbols


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


if __name__ == "__main__":
    unittest.main()
