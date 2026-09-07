#!/usr/bin/env python3
"""Publish a complete signed bundle using a filesystem swap, never in-place edits."""
import ctypes
import datetime
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

source, destination = map(lambda p: Path(p).expanduser().absolute(), sys.argv[1:])
if source == destination or source.suffix != '.app' or destination.suffix != '.app':
    raise SystemExit('Pass distinct source and destination .app paths.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
destination.parent.mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix='.MacThemes-update-', dir=destination.parent))
candidate = staging / destination.name
subprocess.run(['ditto', str(source), str(candidate)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(candidate)], check=True)
if destination.exists():
    archive = Path.home() / 'Library/Caches/MacThemes/Archives/updates' / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    archive.mkdir(parents=True, exist_ok=True)
    # RENAME_SWAP replaces both names atomically and retains the previous bundle.
    libc = ctypes.CDLL(None, use_errno=True)
    swap = libc.renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    swap.restype = ctypes.c_int
    if swap(os.fsencode(candidate), os.fsencode(destination), 2) != 0:
        raise OSError(ctypes.get_errno(), 'Could not atomically replace the app; existing app preserved')
    shutil.move(str(candidate), str(archive / destination.name))
else:
    os.rename(candidate, destination)
staging.rmdir()
print('Published:', destination)
