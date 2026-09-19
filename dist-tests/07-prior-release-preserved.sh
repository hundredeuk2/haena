#!/bin/bash
#
# Proves: publishing this release did not disturb the previous one.
#
# HAE.NA's release policy is that an already-published preview is never overwritten, retagged, or
# deleted — testers must be able to re-download and re-verify exactly the build they tried, and to
# compare an old build against a new one. That is a promise made in the release notes, and this
# check is what makes it falsifiable.
#
# It downloads the *previous* release's asset anonymously and verifies it still matches the
# checksum that release published. It fails if the prior asset was replaced, removed, or its tag
# moved.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="prior-release-preserved"
parse_common_args "$@"

fetch_asset "${PRIOR_TAG}" "${PRIOR_ASSET}"
fetch_checksum_file "${PRIOR_TAG}" "${PRIOR_ASSET}"

PRIOR_ZIP="${WORKDIR}/${PRIOR_ASSET}"
ACTUAL="$(sha256_of "${PRIOR_ZIP}")"
PUBLISHED="$(awk '{print tolower($1)}' "${WORKDIR}/${PRIOR_ASSET}.sha256" | head -n 1)"
DOCUMENTED="$(printf '%s' "${PRIOR_SHA256}" | tr 'A-Z' 'a-z')"

[ "${ACTUAL}" = "${PUBLISHED}" ] || fail "${PRIOR_TAG} asset no longer matches its own published checksum
  downloaded : ${ACTUAL}
  published  : ${PUBLISHED}"

[ "${ACTUAL}" = "${DOCUMENTED}" ] || fail "${PRIOR_TAG} asset changed since it was released
  downloaded : ${ACTUAL}
  documented : ${DOCUMENTED}"

pass "${PRIOR_TAG} is still anonymously downloadable and unchanged (${ACTUAL})"
