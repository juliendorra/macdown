#!/usr/bin/env python3
"""Cheap preflight: resources, XML, workflow economy, and release metadata."""
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
for path in (root / 'MacDown').rglob('*.xib'):
    ET.parse(path)
for path in root.glob('**/*.xcscheme'):
    ET.parse(path)
for path in (root / 'MacDown').glob('*.plist'):
    with path.open('rb') as stream:
        plistlib.load(stream)
# Check real Cocoa setters without loading nibs or starting the application.
# This catches misspelled system outlets before a paid Xcode build.
if sys.platform == 'darwin':
    import ctypes
    ctypes.CDLL('/System/Library/Frameworks/AppKit.framework/AppKit')
    objc = ctypes.CDLL('/usr/lib/libobjc.A.dylib')
    objc.objc_getClass.argtypes = [ctypes.c_char_p]
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.sel_registerName.argtypes = [ctypes.c_char_p]
    objc.sel_registerName.restype = ctypes.c_void_p
    objc.class_getInstanceMethod.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    objc.class_getInstanceMethod.restype = ctypes.c_void_p
    for path in (root / 'MacDown').rglob('*.xib'):
        for node in ET.parse(path).iter():
            name = node.get('customClass', '')
            if not name.startswith('NS'):
                continue
            cls = objc.objc_getClass(name.encode())
            if not cls:
                continue
            for outlet in node.findall('./connections/outlet'):
                prop = outlet.get('property')
                selector = 'set' + prop[0].upper() + prop[1:] + ':'
                method = objc.class_getInstanceMethod(cls, objc.sel_registerName(selector.encode()))
                assert method, f'{path}: {name} has no {selector} outlet setter'
version = (root / 'Tools/version.txt').read_text().strip()
build = (root / 'Tools/build-number.txt').read_text().strip()
assert re.fullmatch(r'\d+\.\d+\.\d+', version), version
assert build.isdigit() and int(build) > 0, build
# Generated reports, credentials, and developer state must stay out of source.
import subprocess
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
for name in filter(None, tracked):
    path = Path(name)
    assert not any(part in {'.build', '.bundle', 'Artifacts', 'Pods', 'node_modules', 'DerivedData', 'xcuserdata', '.DS_Store'}
                   or part.endswith(('.app', '.dSYM', '.xcresult', '.xcarchive', '.xcscmblueprint'))
                   for part in path.parts), f'Generated artifact or developer state tracked: {name}'
    assert not name.startswith('vendor/bundle/'), f'Installed Ruby dependencies tracked: {name}'
    assert path.name != '.env' and not path.name.startswith('.env.'), f'Local credentials tracked: {name}'
assert (root / 'MacDown/Resources/Styles/GitHub-2020.css').stat().st_size > 1000
nib = ET.parse(root / 'MacDown/Localization/Base.lproj/MPDocument.xib')
assert nib.find('.//webView') is None, 'Legacy WebView in document nib'
for path in (root / 'MacDown/Code').rglob('*'):
    if path.suffix not in {'.m', '.h'}:
        continue
    text = path.read_text()
    assert 'setPageSizeMultiplier:' not in text, path
    assert 'NSClassFromString(@"WebCache")' not in text, path
print(f'Project preflight passed — MacDown {version} ({build}).')
