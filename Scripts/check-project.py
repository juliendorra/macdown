#!/usr/bin/env python3
"""Cheap preflight: resources, XML, workflow economy, and release metadata."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
for path in (root / 'MacDown').rglob('*.xib'):
    ET.parse(path)
for path in root.glob('**/*.xcscheme'):
    ET.parse(path)
for path in (root / 'MacDown').glob('*.plist'):
    with path.open('rb') as stream:
        plistlib.load(stream)
version = (root / 'Tools/version.txt').read_text().strip()
build = (root / 'Tools/build-number.txt').read_text().strip()
assert re.fullmatch(r'\d+\.\d+\.\d+', version), version
assert build.isdigit() and int(build) > 0, build
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
