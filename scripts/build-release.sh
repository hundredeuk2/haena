#!/bin/bash
#
# Builds HAE.NA in Release into an isolated DerivedData directory and prints the path of the
# resulting .app.
#
# Isolated on purpose: sharing Xcode's global DerivedData means a package can pick up whatever a
# previous Debug run left behind, which is exactly the kind of thing that makes a release build
# unreproducible.
#
# This does NOT sign or notarize anything. The product is unsigned (ad-hoc) and Gatekeeper will
# warn about it — see README.
#
set -euo pipefail

# Resolve the repository from this script's own location, so it works from any working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DERIVED_DATA="${REPO_ROOT}/.build/DerivedData"
CONFIGURATION="Release"

log() { printf '==> %s\n' "$1" >&2; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ -f "${REPO_ROOT}/project.yml" ] || fail "project.yml not found. Is ${REPO_ROOT} the HAE.NA repository?"

command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found. Install Xcode and run: xcode-select --install"

if ! command -v xcodegen >/dev/null 2>&1; then
    fail "xcodegen not found. Install it with: brew install xcodegen"
fi

log "Regenerating HAENA.xcodeproj from project.yml"
( cd "${REPO_ROOT}" && xcodegen generate >/dev/null )

log "Building ${CONFIGURATION} (unsigned) into .build/DerivedData"
xcodebuild \
    -project "${REPO_ROOT}/HAENA.xcodeproj" \
    -scheme HAENA \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    clean build \
    >"${DERIVED_DATA}.log" 2>&1 || {
        printf 'error: build failed. Last 40 lines:\n' >&2
        tail -40 "${DERIVED_DATA}.log" >&2
        exit 1
    }

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/HAENA.app"
[ -d "${APP_PATH}" ] || fail "build reported success but ${APP_PATH} does not exist"
[ -x "${APP_PATH}/Contents/MacOS/HAENA" ] || fail "built app has no executable at Contents/MacOS/HAENA"

log "Built ${APP_PATH}"
# stdout is only the path, so the packaging script can consume it.
printf '%s\n' "${APP_PATH}"
