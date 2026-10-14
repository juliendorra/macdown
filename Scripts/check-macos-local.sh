#!/usr/bin/env bash
# Native regression checks with Command Line Tools; no Xcode or GitHub runner.
set -euo pipefail
cd "$(dirname "$0")/.."
Scripts/check.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun clang -fobjc-arc -fno-modules -fsanitize=undefined,bounds \
  -fno-sanitize-recover=all -mmacosx-version-min=13.0 \
  -include MacDown/Code/MacDown-Prefix.pch \
  -IMacDown/Code/Application -IMacDown/Code/Document \
  Tests/Native/toolbar-checks.m MacDown/Code/Application/MPToolbarController.m \
  -framework Cocoa -o "$work/toolbar-checks"
"$work/toolbar-checks"
