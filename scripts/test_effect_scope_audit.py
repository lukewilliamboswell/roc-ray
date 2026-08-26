#!/usr/bin/env python3
"""Require phase-guarded hosted effects to emit Observatory effect scopes."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "src" / "host_native.zig"

# Diagnostic annotations are themselves recorder input, rather than hosted
# work to be measured as a hosted effect. These are the only public boundary
# effects intentionally allowed to have a phase guard without EffectScope.
ALLOWLIST = {
    "hostedTraceMark",
    "hostedTraceBegin",
    "hostedTraceEnd",
    "hostedTraceSampleI64",
    "hostedTraceSampleF64",
}


def function_blocks(source: str):
    """Yield (name, body) for Zig functions using brace-depth parsing."""
    # Boundary effects consistently use the `hosted` prefix and single-line
    # signatures. Restricting the audit to that production convention avoids
    # mistaking braces in arbitrary Zig return types for function bodies.
    for match in re.finditer(r"(?m)^fn\s+(hosted[A-Za-z0-9_]+)\s*\([^\n]*\)\s*(?:callconv\([^\n]*\)\s*)?[^\n]*\{", source):
        opening = source.rfind("{", match.start(), match.end())
        if opening < 0:
            continue
        depth = 0
        for offset in range(opening, len(source)):
            if source[offset] == "{":
                depth += 1
            elif source[offset] == "}":
                depth -= 1
                if depth == 0:
                    yield match.group(1), source[opening : offset + 1]
                    break


class EffectScopeAudit(unittest.TestCase):
    def test_every_production_phase_guard_has_effect_scope(self):
        failures = []
        for name, body in function_blocks(SOURCE.read_text()):
            if "enforcePhase(" not in body or name in ALLOWLIST:
                continue
            if "EffectScope.begin(" not in body:
                failures.append(name)
        self.assertEqual([], failures, "phase guards missing EffectScope or explicit allowlist")

    def test_allowlist_is_exact_and_still_guarded(self):
        blocks = dict(function_blocks(SOURCE.read_text()))
        for name in ALLOWLIST:
            self.assertIn(name, blocks)
            self.assertIn("enforcePhase(", blocks[name])
            self.assertNotIn("EffectScope.begin(", blocks[name])


if __name__ == "__main__":
    unittest.main()
