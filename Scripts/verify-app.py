#!/usr/bin/env python3
import plistlib
from pathlib import Path
import sys
root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1])
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleShortVersionString'] == (root / 'Tools/version.txt').read_text().strip(), info
assert info['CFBundleVersion'] == (root / 'Tools/build-number.txt').read_text().strip(), info
assert info['LSMinimumSystemVersion'] == '13.0', info
for resource in ['Base.lproj/MPDocument.nib', 'Prism/components/prism-core.min.js', 'Styles/GitHub-2020.css']:
    assert (app / 'Contents/Resources' / resource).exists(), resource
assert (app / 'Contents/SharedSupport/bin/macdown').is_file()
assert not (app / 'Contents/PlugIns/MacDownTests.xctest').exists(), 'Embedded test bundle'
for item in (app / 'Contents/Frameworks').iterdir():
    assert not item.name.startswith(('XCT', 'XCUnit', 'XCUIAutomation', 'Testing.', '_Testing_', 'libXCTest')), item
print(f"Verified MacDown {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}).")
