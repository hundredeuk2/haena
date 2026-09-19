#!/bin/bash
#
# Proves: the app inside the archive is the version the release claims it is.
#
# Reads CFBundleShortVersionString and CFBundleVersion out of the shipped Info.plist and compares
# them with the version and build passed in (defaulting to this release's). Also checks that the
# asset file name agrees with the version inside the bundle.
#
# It fails if a release is ever cut from a stale build, or if the file name and the binary disagree
# about what is being shipped.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="version-identity"
parse_common_args "$@"

[ -x /usr/libexec/PlistBuddy ] || fail "/usr/libexec/PlistBuddy not found (this check needs macOS)"

ensure_app

ACTUAL_VERSION="$(plist_value CFBundleShortVersionString)"
ACTUAL_BUILD="$(plist_value CFBundleVersion)"

[ -n "${ACTUAL_VERSION}" ] || fail "Info.plist has no CFBundleShortVersionString"
[ -n "${ACTUAL_BUILD}" ]   || fail "Info.plist has no CFBundleVersion"

[ "${ACTUAL_VERSION}" = "${VERSION}" ] \
    || fail "CFBundleShortVersionString is '${ACTUAL_VERSION}', expected '${VERSION}'"
[ "${ACTUAL_BUILD}" = "${BUILD}" ] \
    || fail "CFBundleVersion is '${ACTUAL_BUILD}', expected '${BUILD}'"

case "${ASSET}" in
    *"${VERSION}-${BUILD}"*) ;;
    *) fail "asset name '${ASSET}' does not carry the version and build inside the bundle (${VERSION} ${BUILD})" ;;
esac

# The release notes state a minimum macOS; a build that quietly raises it would strand testers.
MIN_OS="$(plist_value LSMinimumSystemVersion)"
log "LSMinimumSystemVersion = ${MIN_OS:-<unset>}"

pass "shipped bundle reports version ${ACTUAL_VERSION} (${ACTUAL_BUILD}), matching the release"
