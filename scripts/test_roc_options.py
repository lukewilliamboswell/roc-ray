"""Keep compiler workarounds confined to the reproduced failures."""

from pathlib import Path
import unittest
from unittest.mock import patch

import roc_options


class CompilerOptionsTests(unittest.TestCase):
    def test_ordinary_commands_keep_the_cache(self):
        with patch.object(roc_options, "compiler_version", side_effect=AssertionError("unneeded version query")):
            for command in ["check", "test", "build"]:
                self.assertEqual([], roc_options.compiler_args("roc", command, Path("examples/camera/main.roc")))
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

    def test_november_23_workarounds_are_confined_to_top_down(self):
        top_down = Path("examples/top_down/main.roc")
        version = "Roc compiler version nightly-2026-11-23-b5c77fc"
        with patch.object(roc_options, "compiler_version", return_value=version):
            self.assertEqual(["--no-cache"], roc_options.compiler_args("roc", "check", top_down))
            for command in ["build", "test"]:
                self.assertEqual(["--specialize=yes"], roc_options.compiler_args("roc", command, top_down))
            self.assertEqual([], roc_options.compiler_args("roc", "test", Path("platform/Devices.roc")))

    def test_november_24_workaround_targets_only_top_down_tests(self):
        top_down = Path("examples/top_down/main.roc")
        version = "Roc compiler version nightly-2026-11-24-ff5e544"
        with patch.object(roc_options, "compiler_version", return_value=version):
            self.assertEqual(["--specialize=yes"], roc_options.compiler_args("roc", "test", top_down))
            for command in ["check", "build"]:
                self.assertEqual([], roc_options.compiler_args("roc", command, top_down))
            self.assertEqual([], roc_options.compiler_args("roc", "test", Path("platform/Devices.roc")))

    def test_native_lowering_workaround_retains_cache(self):
        with patch.object(roc_options, "compiler_version", return_value="Roc compiler version nightly-2026-11-18-a520eed"):
            for command in ["build", "test"]:
                self.assertEqual(["--specialize=yes"], roc_options.compiler_args("roc", command, Path("examples/top_down/main.roc")))

    def test_cached_test_allocation_exceptions_are_host_specific(self):
        version = "Roc compiler version nightly-2026-11-18-a520eed"
        with patch.object(roc_options, "compiler_version", return_value=version):
            for system, machine, source in [
                ("Darwin", "x86_64", "examples/pong/main.roc"),
                ("Darwin", "x86_64", "examples/snake/main.roc"),
                ("Darwin", "x86_64", "examples/sqlite_scores/main.roc"),
                ("Windows", "AMD64", "docs/tutorial/primer.roc"),
                ("Windows", "AMD64", "docs/tutorial/smallest.roc"),
                ("Windows", "AMD64", "docs/tutorial/step6.roc"),
            ]:
                with self.subTest(system=system, source=source), patch.object(roc_options.platform, "system", return_value=system), patch.object(roc_options.platform, "machine", return_value=machine):
                    self.assertEqual(["--no-cache"], roc_options.compiler_args("roc", "test", Path(source)))
                    self.assertEqual([], roc_options.compiler_args("roc", "check", Path(source)))
                    self.assertEqual([], roc_options.compiler_args("roc", "build", Path(source)))
            with patch.object(roc_options.platform, "system", return_value="Linux"):
                self.assertEqual([], roc_options.compiler_args("roc", "test", Path("examples/pong/main.roc")))
                self.assertEqual([], roc_options.compiler_args("roc", "test", Path("docs/tutorial/primer.roc")))
            with patch.object(roc_options.platform, "system", return_value="Darwin"), patch.object(roc_options.platform, "machine", return_value="arm64"):
                self.assertEqual([], roc_options.compiler_args("roc", "test", Path("examples/pong/main.roc")))

    def test_workaround_does_not_follow_other_compilers(self):
        with patch.object(roc_options, "compiler_version", return_value="Roc compiler version nightly-2026-11-19-abcdef0"):
            self.assertEqual([], roc_options.compiler_args("roc", "build", Path("examples/top_down/main.roc")))
            self.assertEqual([], roc_options.compiler_args("roc", "test", Path("platform/Devices.roc")))


if __name__ == "__main__":
    unittest.main()
