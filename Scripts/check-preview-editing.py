#!/usr/bin/env python3
"""Run isolated preview-editing checks against an already built development app.
Requires only local macOS Command Line Tools, no Xcode or GitHub runner.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
from macos_test_support import require_desktop_access

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--output', type=Path, default=ROOT/'Artifacts/PreviewEditingChecks')
args = parser.parse_args()
require_desktop_access()
args.output = args.output.resolve()
args.output.mkdir(parents=True, exist_ok=True)
(args.output/'results.json').unlink(missing_ok=True)
dylib = args.output/'preview-edit-checks.dylib'
subprocess.run(['xcrun','clang','-dynamiclib','-fobjc-arc','-fno-modules','-undefined','dynamic_lookup',
                '-I'+str(ROOT/'MacDown/Code/Document'),'-framework','Cocoa','-framework','WebKit',
                str(ROOT/'Tests/Native/preview-edit-checks.m'),'-o',str(dylib)], check=True)
subprocess.run(['codesign','--force','--sign','-',str(dylib)], check=True)
with tempfile.TemporaryDirectory(prefix='macdown-preview-edit-') as temporary:
    fixture = Path(temporary)/'document.md'
    fixture.write_text('# Café 😀\n\nHello **bold** and [link](https://example.com/link).\n\n- [x] Done\n- Next\n\n```javascript\nconst x = 42;\n```\n\n| Name | Value |\n| --- | --- |\n| A | B |\n')
    env = os.environ.copy()
    env.update(DYLD_INSERT_LIBRARIES=str(dylib),MACDOWN_EDIT_DOCUMENT=str(fixture),MACDOWN_EDIT_OUTPUT=str(args.output/'results.json'))
    with (args.output/'checks.log').open('w') as log:
        result = subprocess.run([str(args.app.resolve()/'Contents/MacOS/MacDown'),'-ApplePersistenceIgnoreState','YES'],env=env,stdout=log,stderr=log,timeout=90)
    if result.returncode:
        raise RuntimeError((args.output/'checks.log').read_text()[-8000:])
print(json.dumps(json.loads((args.output/'results.json').read_text()),indent=2))
