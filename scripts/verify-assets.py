#!/usr/bin/env python3
"""Verify pinned font bytes and the original Git blob IDs of bundled wallpapers."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
fonts = root / 'Vendor/NerdFonts'
manifest = json.loads((fonts / 'origin.json').read_text())
expected = set()
for entry in manifest['files']:
    path = fonts / entry['path'].removeprefix('patched-fonts/')
    if not path.resolve().is_relative_to(fonts.resolve()):
        raise SystemExit('Invalid font manifest path')
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
        raise SystemExit(f'Font checksum mismatch: {path.name}')
    expected.add(path.relative_to(fonts))
actual = {p.relative_to(fonts) for p in fonts.rglob('*') if p.is_file()}
if actual != expected | {Path('origin.json')}:
    raise SystemExit('Unmanifested or missing font files')
if len([p for p in expected if p.suffix == '.ttf']) != 16:
    raise SystemExit('Expected exactly 16 curated font faces')
wallpapers = root / 'Vendor/Omarchy'
for entry in json.loads((wallpapers / 'backgrounds-origin.json').read_text())['files']:
    path = wallpapers / entry['path'].removeprefix('themes/')
    if not path.resolve().is_relative_to(wallpapers.resolve()):
        raise SystemExit('Invalid wallpaper manifest path')
    data = path.read_bytes()
    if hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() != entry['sha']:
        raise SystemExit(f'Wallpaper checksum mismatch: {path.name}')
print('PASS: vendored font and wallpaper provenance')
