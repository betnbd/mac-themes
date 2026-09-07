#!/usr/bin/env python3
"""Check the actual ZIP and extracted signature; accepts local and release archives."""
import plistlib
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
archive = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'dist/Mac Themes.zip'
with zipfile.ZipFile(archive) as package:
    if package.testzip() is not None:
        raise SystemExit('ZIP integrity check failed')
    names = package.namelist()
    if any('/._' in n or '/trash/' in n or n.endswith(('.swift', '.log')) for n in names):
        raise SystemExit('Unexpected development files or metadata in package')
    if len([n for n in names if n.endswith('.ttf')]) != 16:
        raise SystemExit('Incorrect font count')
    if len([n for n in names if '/BuiltinWallpapers/' in n and not n.endswith('/')]) != 32:
        raise SystemExit('Incorrect wallpaper count')
    actual = plistlib.loads(package.read('Mac Themes.app/Contents/Info.plist'))
    expected = plistlib.loads((root / 'scripts/Info.plist').read_bytes())
    for key in ['CFBundleIdentifier', 'CFBundleVersion', 'CFBundleShortVersionString']:
        if actual[key] != expected[key]:
            raise SystemExit(f'Package metadata mismatch: {key}')
with tempfile.TemporaryDirectory(prefix='MacThemes-verify-') as stage:
    subprocess.run(['ditto', '-x', '-k', str(archive), stage], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(Path(stage) / 'Mac Themes.app')], check=True)
print('PASS: package contents, version, ZIP integrity and extracted signature')
