#!/bin/bash
#
# Proves: the download really is the universal binary it is advertised as, so it runs natively on
# both Apple silicon and Intel Macs.
#
# Reads the architectures out of the shipped Mach-O with `lipo` and requires every expected slice
# to be present. It fails if a release is ever cut as a single-architecture build while still being
# described as universal — which would silently exclude half the testers.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="architecture"
parse_common_args "$@"

EXPECTED_ARCHS="${HAENA_ARCHS:-x86_64 arm64}"

require_tool lipo
ensure_app
BIN="$(app_binary_path)"

ARCHS="$(lipo -archs "${BIN}" 2>/dev/null || true)"
[ -n "${ARCHS}" ] || fail "lipo could not read architectures from Contents/MacOS/${APP_BINARY_NAME}"

for want in ${EXPECTED_ARCHS}; do
    case " ${ARCHS} " in
        *" ${want} "*) ;;
        *) fail "the shipped binary is missing the ${want} slice; it contains: ${ARCHS}" ;;
    esac
done

pass "universal binary confirmed: ${ARCHS}"
