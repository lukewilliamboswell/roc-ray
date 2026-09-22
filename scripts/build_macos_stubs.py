#!/usr/bin/env python3
"""Generate project-authored macOS linker interfaces from a reviewed symbol catalog.

Inputs are project source records and compiled host archives. No SDK headers,
TBDs, or framework binaries are read. The generated interfaces contain names
and linkage metadata only; macOS supplies the implementations at runtime.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'dependencies/macos-interfaces/interfaces.json'
PROVENANCE = ROOT / 'dependencies/macos-interfaces/PROVENANCE.md'
ARCHIVES = ('libhost.a', 'libraylib.a', 'libmsf_gif.a', 'libvpx.a', 'libsqlite3.a')
TAPI_TARGETS = ('x86_64-macos', 'arm64-macos')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_catalog(path=CATALOG):
    return validate_catalog(json.loads(path.read_bytes()))


def validate_catalog(catalog):
    if (set(catalog) != {'schema_version', 'target', 'selection', 'libraries'}
            or catalog['schema_version'] != 1 or catalog['target'] != 'x86_64-macos+arm64-macos'
            or not isinstance(catalog['selection'], str) or not catalog['selection']):
        raise ValueError('unsupported macOS interface catalog')
    seen_paths, seen_symbols = set(), set()
    for library in catalog['libraries']:
        required = {'name', 'path', 'install_name', 'path_sources', 'symbols'}
        if not required <= set(library) <= required | {'path_evidence', 'load_requirement', 'reexports'}:
            raise ValueError('invalid macOS library evidence schema')
        name = library['path']
        relative = PurePosixPath(name)
        if (relative.is_absolute() or '..' in relative.parts or str(relative) != name
                or '\\' in name or relative.suffix != '.tbd' or name in seen_paths):
            raise ValueError('invalid or duplicate macOS interface path')
        seen_paths.add(name)
        if not re.fullmatch(r'/(?:usr/lib|System/Library/Frameworks)/[A-Za-z0-9_./+-]+', library['install_name']):
            raise ValueError('invalid macOS install name')
        if (not isinstance(library['path_sources'], list) or not library['path_sources']
                or any(not isinstance(url, str) or not url.startswith('https://')
                       for url in library['path_sources'])):
            raise ValueError('macOS library requires install-path evidence')
        reexports = library.get('reexports', [])
        if (not isinstance(reexports, list) or len(reexports) != len(set(reexports))
                or any(not isinstance(name, str) or not re.fullmatch(
                    r'/(?:usr/lib|System/Library/Frameworks)/[A-Za-z0-9_./+-]+', name)
                    for name in reexports)):
            raise ValueError('invalid macOS reexport')
        for record in library['symbols']:
            if set(record) != {'name', 'sources'} or not isinstance(record['sources'], list):
                raise ValueError('invalid macOS symbol evidence schema')
            symbol = record['name']
            # arm64 Mach-O archives can reference selector-specialized Objective-C
            # message stubs such as `_objc_msgSend$setTitle:`. Colons are valid in
            # those linker symbols and remain safely single-quoted in TBD output.
            if not re.fullmatch(r'[A-Za-z_$][A-Za-z0-9_$.:]*', symbol) or symbol in seen_symbols:
                raise ValueError('invalid or duplicate macOS symbol')
            if not record['sources']:
                raise ValueError(f'macOS symbol requires source evidence: {symbol}')
            for source in record['sources']:
                if (not isinstance(source, dict) or not isinstance(source.get('url'), str)
                        or not source['url'].startswith('https://')
                        or not re.fullmatch(r'[0-9a-f]{64}', source.get('response_sha256', ''))):
                    raise ValueError(f'macOS symbol requires hash-bound HTTPS evidence: {symbol}')
                kind = source.get('evidence_kind')
                if kind not in {'exact_C_identifier', 'exact_function_name_in_manpage_synopsis',
                                'public_open_source_identifier', 'public_open_source_ABI_suffix'}:
                    raise ValueError(f'unsupported macOS evidence kind: {symbol}')
                if kind == 'exact_C_identifier' and not all(key in source for key in
                        ('data_url', 'external_id', 'title', 'documented_modules', 'retrieved_at')):
                    raise ValueError(f'incomplete documentation evidence: {symbol}')
                if kind == 'exact_function_name_in_manpage_synopsis' and not all(
                        key in source for key in ('documented_modules', 'retrieved_at')):
                    raise ValueError(f'incomplete manual-page evidence: {symbol}')
                if kind.startswith('public_open_source_') and not source.get('identifier'):
                    raise ValueError(f'incomplete open-source evidence: {symbol}')
            seen_symbols.add(symbol)
    if 'usr/lib/libSystem.tbd' not in seen_paths:
        raise ValueError('macOS interface catalog requires libSystem')
    return catalog


def render(catalog):
    """Emit deterministic TBD v4 YAML without SDK versions or UUIDs."""
    files = {}
    for library in catalog['libraries']:
        target_list = ', '.join(TAPI_TARGETS)
        lines = ['--- !tapi-tbd', 'tbd-version: 4', f'targets: [ {target_list} ]',
                 "install-name: '" + library['install_name'] + "'"]
        if library.get('reexports'):
            lines += ['reexported-libraries:', f'  - targets: [ {target_list} ]',
                      '    libraries:']
            lines += ["      - '" + name + "'" for name in sorted(library['reexports'])]
        symbols = sorted(record['name'] for record in library['symbols'])
        if symbols:
            lines += ['exports:', f'  - targets: [ {target_list} ]', '    symbols:']
            lines += ["      - '" + symbol + "'" for symbol in symbols]
        files[library['path']] = ('\n'.join(lines + ['...', ''])).encode()
    return files


def generate(archives, destination, catalog_path=CATALOG):
    """Bind generated interfaces to exact macOS archive inputs in a fresh output tree."""
    catalog_bytes = catalog_path.read_bytes()
    catalog = validate_catalog(json.loads(catalog_bytes))
    files = render(catalog)
    identities = {}
    for name in ARCHIVES:
        path = archives / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'missing or invalid macOS host archive: {path}')
        identities[name] = digest(path.read_bytes())
    provenance = PROVENANCE.read_bytes()
    manifest = {'schema_version': 1, 'origin': 'project-generated-macos-interfaces',
                'target': catalog['target'], 'host_archives_sha256': identities,
                'catalog_sha256': digest(catalog_bytes),
                'generator_sha256': digest(Path(__file__).read_bytes()),
                'provenance_sha256': digest(provenance),
                'files_sha256': {name: digest(data) for name, data in sorted(files.items())}}
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(destination)
    destination.mkdir(parents=True)
    for name, data in files.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (destination / 'interfaces.json').write_bytes(catalog_bytes)
    (destination / 'PROVENANCE.md').write_bytes(provenance)
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def install(targets):
    """Replace local interface outputs only after complete generation succeeds."""
    with tempfile.TemporaryDirectory(prefix='.generated-macos-', dir=targets) as temporary:
        candidate = Path(temporary) / 'macos-sysroot'
        manifest = generate(targets / 'arm64mac', candidate)
        destination = targets / 'macos-sysroot'
        backup = Path(temporary) / 'previous'
        if destination.exists() or destination.is_symlink():
            destination.rename(backup)
        try:
            candidate.rename(destination)
        except OSError:
            if backup.exists() or backup.is_symlink():
                backup.rename(destination)
            raise
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archives', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    manifest = generate(args.archives.resolve(), args.output.resolve())
    print(json.dumps({'files': len(manifest['files_sha256']), 'origin': manifest['origin']}))
