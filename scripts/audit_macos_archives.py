#!/usr/bin/env python3
"""Inventory external references in macOS archives without reading an SDK."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re
import subprocess

from build_macos_stubs import ARCHIVES, read_catalog


APPLICATION_CALLBACKS = frozenset({
    "_app_config_for_host", "_drop_model_for_host", "_init_for_host",
    "_render_for_host", "_run_task_for_host", "_update_for_host",
})
OBJC_SELECTOR_PREFIX = "_objc_msgSend$"


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


def verify_closure(report: dict, catalog: dict) -> dict:
    """Classify every conservative archive reference without treating it as provenance."""
    catalog_symbols = {
        symbol["name"] for library in catalog["libraries"] for symbol in library["symbols"]
    }
    external = {item["name"] for item in report["external_symbols"]}
    callbacks = sorted(external & APPLICATION_CALLBACKS)
    missing_callbacks = sorted(APPLICATION_CALLBACKS - external)
    callback_exports = sorted(APPLICATION_CALLBACKS & catalog_symbols)
    selector_stubs = sorted(name for name in external if name.startswith(OBJC_SELECTOR_PREFIX))
    if selector_stubs and "_objc_msgSend" not in catalog_symbols:
        raise ValueError("Objective-C selector stubs require _objc_msgSend in the reviewed catalog")
    covered = catalog_symbols | APPLICATION_CALLBACKS | set(selector_stubs)
    uncovered = sorted(external - covered)
    if missing_callbacks or callback_exports or uncovered:
        raise ValueError(json.dumps({
            "missing_application_callbacks": missing_callbacks,
            "callbacks_in_system_catalog": callback_exports,
            "uncovered_external_symbols": uncovered,
        }, sort_keys=True))
    result = dict(report)
    result["classification"] = {
        "catalogued_system_interfaces": len(external & catalog_symbols),
        "application_callbacks": callbacks,
        "objc_selector_stubs_resolved_via_objc_msgSend": selector_stubs,
        "uncovered_external_symbols": [],
    }
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archives", nargs="+", type=Path)
    parser.add_argument("--llvm-nm", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--verify-closure", action="store_true")
    args = parser.parse_args()
    archives = [path.resolve() for path in args.archives]
    if len(set(archives)) != len(archives):
        parser.error("duplicate archive inputs")
    if tuple(path.name for path in archives) != ARCHIVES:
        parser.error("archives must be the complete ordered RocRay macOS input set")
    report = audit(archives, args.llvm_nm)
    if args.verify_closure:
        report = verify_closure(report, read_catalog(args.catalog) if args.catalog else read_catalog())
    result = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")
