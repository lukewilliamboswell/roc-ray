#!/usr/bin/env python3
"""Inventory external references in macOS archives without reading an SDK."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess


def parse_symbols(output: str, archive: Path):
    pattern = re.compile(re.escape(str(archive)) + r"\[(.+)\]: (\S+) ([A-Za-z?]) ([0-9a-fA-F]+|-+) ([0-9a-fA-F]+)")
    references = defaultdict(set)
    definitions = set()
    kinds = defaultdict(int)
    for line in output.splitlines():
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError(f"unrecognized llvm-nm record: {line}")
        member, symbol, kind, _, _ = match.groups()
        kinds[kind] += 1
        if kind in ("U", "w", "v"):
            references[symbol].add(member)
        elif kind in ("A", "B", "C", "D", "G", "I", "R", "S", "T", "V", "W"):
            definitions.add(symbol)
        else:
            raise ValueError(f"unclassified llvm-nm symbol kind {kind}: {symbol}")
    return references, definitions, dict(sorted(kinds.items()))


def audit(archives: list[Path], tool: Path) -> dict:
    references = defaultdict(list)
    definitions = set()
    records = []
    version = subprocess.check_output([str(tool), "--version"], text=True).strip()
    for index, archive in enumerate(archives):
        before = hashlib.sha256(archive.read_bytes()).hexdigest()
        result = subprocess.run([
            str(tool), "--format=posix", "--print-file-name", "--extern-only",
            "--no-demangle", str(archive),
        ], capture_output=True, text=True, check=True)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != before:
            raise ValueError(f"archive changed during inspection: {archive}")
        imported, provided, kinds = parse_symbols(result.stdout, archive)
        definitions.update(provided)
        for symbol, members in imported.items():
            references[symbol].extend({"archive": index, "member": member} for member in sorted(members))
        records.append({"name": archive.name, "sha256": before,
                        "symbol_records_by_kind": kinds,
                        "defined_symbol_count": len(provided),
                        "referenced_symbol_count": len(imported),
                        "reader_diagnostics": result.stderr.splitlines()})
    external = sorted(references.keys() - definitions)
    return {
        "schema_version": 1,
        "reader_version": version,
        "archives": records,
        "scope": "All external archive references minus definitions in supplied archives, before dead stripping.",
        "limitations": "Does not establish ownership, weak-import behavior, final reachability, or provenance.",
        "external_symbol_count": len(external),
        "external_symbols": [{"name": symbol, "references": references[symbol]} for symbol in external],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", nargs="+", type=Path)
    parser.add_argument("--llvm-nm", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    archives = [path.resolve() for path in args.archives]
    if len(set(archives)) != len(archives):
        parser.error("duplicate archive inputs")
    result = json.dumps(audit(archives, args.llvm_nm), indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")
