#!/bin/bash
#
# Proves: the archive is a usable macOS application, not a folder of loose files or a double-wrapped
# archive.
#
# Checks that it expands to exactly one top-level `HAE.NA.app`, that the bundle has the three parts
# macOS requires to launch it (Contents/Info.plist, Contents/MacOS, and an executable binary at
# Contents/MacOS/HAENA), and that the binary is really a Mach-O executable.
#
# It fails if packaging ever changes shape in a way that would leave a downloader with something
# they cannot open.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="bundle-shape"
parse_common_args "$@"

ensure_app
ROOT="${EXTRACT_ROOT}"

# Exactly one visible top-level entry, and it is the app. `__MACOSX` and dotfiles are ignored:
# ditto -c -k --sequesterRsrc may legitimately add resource-fork metadata.
TOP="$(ls -1 "${ROOT}" | grep -v '^__MACOSX$' | grep -v '^\.' || true)"
if [ "${TOP}" != "${APP_NAME}" ]; then
    fail "expected the archive to expand to exactly ${APP_NAME}, found:
${TOP}"
fi

[ -f "${APP_PATH}/Contents/Info.plist" ] || fail "missing ${APP_NAME}/Contents/Info.plist"
[ -d "${APP_PATH}/Contents/MacOS" ]      || fail "missing ${APP_NAME}/Contents/MacOS"

BIN="$(app_binary_path)"
[ -f "${BIN}" ] || fail "missing executable at Contents/MacOS/${APP_BINARY_NAME}"
[ -x "${BIN}" ] || fail "Contents/MacOS/${APP_BINARY_NAME} exists but is not executable"

# The Info.plist must point at the binary that is actually there.
DECLARED="$(plist_value CFBundleExecutable)"
[ "${DECLARED}" = "${APP_BINARY_NAME}" ] \
    || fail "CFBundleExecutable is '${DECLARED}' but the shipped binary is '${APP_BINARY_NAME}'"

require_tool file
if ! file -b "${BIN}" | grep -qi 'Mach-O'; then
    fail "Contents/MacOS/${APP_BINARY_NAME} is not a Mach-O executable: $(file -b "${BIN}")"
fi

pass "${ASSET} expands to ${APP_NAME} with a Mach-O executable at Contents/MacOS/${APP_BINARY_NAME}"
