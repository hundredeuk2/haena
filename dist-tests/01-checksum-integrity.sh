#!/bin/bash
#
# Proves: the file a stranger downloads from the release page is byte-for-byte the file the
# release notes describe.
#
# Downloads the asset and its published `.sha256` anonymously — no token, no `gh`, no netrc — then
# compares three things that must all agree:
#   1. the SHA-256 recomputed from the downloaded bytes,
#   2. the SHA-256 published next to the asset,
#   3. the SHA-256 written in the release notes and README (passed in / defaulted here).
#
# It fails if the artifact was replaced, truncated, or silently rebuilt, and it fails if the release
# is not actually anonymously downloadable.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="checksum-integrity"
parse_common_args "$@"

fetch_asset "${TAG}" "${ASSET}"
fetch_checksum_file "${TAG}" "${ASSET}"

ZIP="${WORKDIR}/${ASSET}"
ACTUAL_SHA="$(sha256_of "${ZIP}")"
ACTUAL_BYTES="$(bytes_of "${ZIP}")"

# The published .sha256 is `<hex>  <filename>`; take the hex and lowercase it.
PUBLISHED_SHA="$(awk '{print tolower($1)}' "${WORKDIR}/${ASSET}.sha256" | head -n 1)"
PUBLISHED_NAME="$(awk '{print $2}' "${WORKDIR}/${ASSET}.sha256" | head -n 1)"

[ -n "${PUBLISHED_SHA}" ] || fail "the published ${ASSET}.sha256 did not contain a checksum"

if [ "${ACTUAL_SHA}" != "${PUBLISHED_SHA}" ]; then
    fail "downloaded bytes do not match the published checksum
  downloaded : ${ACTUAL_SHA}
  published  : ${PUBLISHED_SHA}"
fi

if [ "${ACTUAL_SHA}" != "$(printf '%s' "${EXPECTED_SHA256}" | tr 'A-Z' 'a-z')" ]; then
    fail "downloaded bytes do not match the checksum documented in the release notes
  downloaded : ${ACTUAL_SHA}
  documented : ${EXPECTED_SHA256}"
fi

if [ -n "${PUBLISHED_NAME}" ] && [ "${PUBLISHED_NAME##*/}" != "${ASSET}" ]; then
    fail "the published checksum file names a different artifact: ${PUBLISHED_NAME}"
fi

if [ -n "${EXPECTED_BYTES}" ] && [ "${ACTUAL_BYTES}" != "${EXPECTED_BYTES}" ]; then
    fail "downloaded size ${ACTUAL_BYTES} bytes, expected ${EXPECTED_BYTES} bytes"
fi

pass "${ASSET} downloaded anonymously from ${TAG}: ${ACTUAL_BYTES} bytes, SHA-256 ${ACTUAL_SHA}"
pass "recomputed, published, and documented checksums all agree"
