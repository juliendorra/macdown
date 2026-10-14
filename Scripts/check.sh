#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/check-project.py
node --check MacDown/Resources/Extensions/preview-update.js
node --check MacDown/Resources/Extensions/preview-edit.js
node Tests/Portable/preview-edit-tests.js
python3 -m unittest discover -s Tests/Pipeline -p '*_tests.py'
ruby Tests/Pipeline/workflow-tests.rb
python3 - <<'PY'
import ast
from pathlib import Path
for path in Path('Scripts').glob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
PY
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
