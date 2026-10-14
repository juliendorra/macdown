# Canonical, reproducible version metadata shared by the app and CLI.
MP_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
get_build_version() { git describe --tags --always --dirty=+; }
get_short_version() { cat "$MP_TOOLS_DIR/version.txt"; }
get_bundle_version() { cat "$MP_TOOLS_DIR/build-number.txt"; }
