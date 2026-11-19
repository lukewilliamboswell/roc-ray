"""Keep compiler workarounds confined to the reproduced failures."""

from pathlib import Path
import unittest
from unittest.mock import patch

import roc_options


class CompilerOptionsTests(unittest.TestCase):
    def test_ordinary_commands_keep_the_cache(self):
        with patch.object(roc_options, "compiler_version", side_effect=AssertionError("unneeded version query")):
            for command in ["check", "test", "build"]:
                self.assertEqual([], roc_options.compiler_args("roc", command, Path("examples/pong/main.roc")))
            self.assertEqual([], roc_options.compiler_args("roc", "test", Path("examples/top_down/main.roc")))
            self.assertEqual([], roc_options.compiler_args("roc", "build", Path("examples/roc-doom-e1m1/main.roc")))

    def test_reproduced_failures_use_source_compilation(self):
        version = "Roc compiler version nightly-2026-11-18-a520eed"
        with patch.object(roc_options, "compiler_version", return_value=version):
            for command, source in [
                ("check", "examples/top_down/main.roc"),
                ("test", "examples/roc-doom-e1m1/main.roc"),
                ("test", "platform/Devices.roc"),
            ]:
                with self.subTest(command=command, source=source):
                    self.assertEqual(["--no-cache"], roc_options.compiler_args("roc", command, Path(source)))

    def test_native_lowering_workaround_retains_cache(self):
        with patch.object(roc_options, "compiler_version", return_value="Roc compiler version nightly-2026-11-18-a520eed"):
            self.assertEqual(["--specialize=yes"], roc_options.compiler_args("roc", "build", Path("examples/top_down/main.roc")))

    def test_workaround_does_not_follow_other_compilers(self):
        with patch.object(roc_options, "compiler_version", return_value="Roc compiler version nightly-2026-11-19-abcdef0"):
            self.assertEqual([], roc_options.compiler_args("roc", "build", Path("examples/top_down/main.roc")))
            self.assertEqual([], roc_options.compiler_args("roc", "test", Path("platform/Devices.roc")))


if __name__ == "__main__":
    unittest.main()
