#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Bundler and CocoaPods are pinned by the lockfiles. Ruby 3.3+ is required.
bundle check || bundle install
git submodule update --init --depth 1 Dependency/prism
bundle exec pod install --deployment
make -C Dependency/peg-markdown-highlight
