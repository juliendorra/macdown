#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/check-project.py
if command -v node >/dev/null 2>&1; then
  node --check MacDown/Resources/Extensions/preview-update.js
fi
for script in Scripts/*.sh Tools/*.sh; do bash -n "$script"; done
ruby -c Podfile
make -C Dependency/peg-markdown-highlight
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
${CC:-cc} -std=gnu99 -O2 -IDependency/peg-markdown-highlight \
  Tests/Portable/parser-tests.c Dependency/peg-markdown-highlight/pmh_parser.c \
  -o "$work/parser-tests"
"$work/parser-tests"
git diff --check
