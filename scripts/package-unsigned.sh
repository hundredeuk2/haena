#!/bin/bash
#
# Packages an unsigned HAE.NA Developer Preview into dist/ with a SHA-256 checksum.
#
# Produces a .app.zip rather than a .dmg. A zip is what `ditto` produces losslessly, what GitHub
# Releases serve directly, and what a user can verify with one shasum command. A DMG would add a
# mount step and a background-image layout that buys nothing for an unsigned build nobody can
# verify by signature anyway.
#
# Nothing here signs or notarizes. The name says "unsigned" so the artifact cannot be mistaken for
# a signed build.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

log() { printf '==> %s\n' "$1" >&2; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }

APP_PATH="$("${SCRIPT_DIR}/build-release.sh")"

PLIST="${APP_PATH}/Contents/Info.plist"
[ -f "${PLIST}" ] || fail "no Info.plist in the built app"

# Version comes from the built product, never from project.yml: what ships is what was built.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
[ -n "${VERSION}" ] || fail "could not read CFBundleShortVersionString"
log "Version ${VERSION} (build ${BUILD}) — UNSIGNED, not notarized"

ARTIFACT="HAE.NA-${VERSION}-${BUILD}-unsigned.app.zip"
FINAL_PATH="${DIST_DIR}/${ARTIFACT}"

mkdir -p "${DIST_DIR}"
if [ -e "${FINAL_PATH}" ]; then
    fail "${FINAL_PATH} already exists. Remove it, or bump the version, rather than overwriting a published artifact."
fi

# --- refuse to ship anything that is not the app ------------------------------------------------
# A packaged build that carries a key or someone's meeting audio is the one mistake this whole
# release process exists to prevent, so it is checked rather than assumed.
log "Checking the app bundle for user data and credentials"
LEAKS="$(find "${APP_PATH}" -type f \( \
    -name "*.m4a" -o -name "*.wav" -o -name "*.mp3" -o -name "*.webm" -o \
    -name "projects.json" -o -name "profile.json" -o -name "agent-jobs.json" -o \
    -name "agent-ledger.json" -o -name ".env*" \) 2>/dev/null || true)"
[ -z "${LEAKS}" ] || fail "the app bundle contains files that must not ship:"$'\n'"${LEAKS}"

if grep -rlqE "sk-(proj|svcacct|admin)?-?[A-Za-z0-9_-]{20,}" "${APP_PATH}" 2>/dev/null; then
    fail "something inside the app bundle looks like an API key"
fi

# --- package ------------------------------------------------------------------------------------
# Built in a temp directory and moved into place only on success, so a failure never leaves a
# half-written archive that looks finished.
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

STAGE="${TMP_DIR}/HAE.NA.app"
log "Staging the app"
ditto "${APP_PATH}" "${STAGE}"

log "Creating ${ARTIFACT}"
# --keepParent so the archive expands to HAE.NA.app rather than scattering its contents.
ditto -c -k --sequesterRsrc --keepParent "${STAGE}" "${TMP_DIR}/${ARTIFACT}"

( cd "${TMP_DIR}" && shasum -a 256 "${ARTIFACT}" > "${ARTIFACT}.sha256" )

mv "${TMP_DIR}/${ARTIFACT}" "${FINAL_PATH}"
mv "${TMP_DIR}/${ARTIFACT}.sha256" "${FINAL_PATH}.sha256"

SIZE="$(du -h "${FINAL_PATH}" | cut -f1 | tr -d ' ')"

cat >&2 <<EOF

==> Done. UNSIGNED Developer Preview — not signed, not notarized.

    Artifact : ${FINAL_PATH} (${SIZE})
    Checksum : ${FINAL_PATH}.sha256
    SHA-256  : $(cut -d' ' -f1 "${FINAL_PATH}.sha256")

    Users must open it with right-click -> Open the first time, and should verify the
    checksum against the one published with the release. See README.
EOF
