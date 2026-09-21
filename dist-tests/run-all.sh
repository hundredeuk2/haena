#!/bin/bash
#
# Runs every HAE.NA public distribution check against a published release.
#
#   ./run-all.sh                          # the current release (defaults in lib/common.sh)
#   ./run-all.sh --version 0.2.8 --build 13 --tag v0.2.8-preview.1 --sha256 <hex>   # any other release
#
# The release asset is downloaded once into a shared work directory and reused by every check.
# Exits non-zero if any check fails, after running them all, and prints which ones failed.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="run-all"
parse_common_args "$@"

# Share one download/extract cache across the individual checks.
export HAENA_DIST_TEST_WORKDIR="${WORKDIR}"
export HAENA_REPO="${REPO}" HAENA_TAG="${TAG}" HAENA_VERSION="${VERSION}" HAENA_BUILD="${BUILD}"
export HAENA_ASSET="${ASSET}" HAENA_SHA256="${EXPECTED_SHA256}" HAENA_BYTES="${EXPECTED_BYTES}"
export HAENA_PRIOR_TAG="${PRIOR_TAG}" HAENA_PRIOR_ASSET="${PRIOR_ASSET}" HAENA_PRIOR_SHA256="${PRIOR_SHA256}"

mkdir -p "${WORKDIR}"

printf '\nHAE.NA distribution tests\n' >&2
printf '  repository : %s\n' "${REPO}" >&2
printf '  release    : %s (%s build %s)\n' "${TAG}" "${VERSION}" "${BUILD}" >&2
printf '  asset      : %s\n' "${ASSET}" >&2
printf '  work dir   : %s\n\n' "${WORKDIR}" >&2

FAILED=()
PASSED=0

for check in "${SCRIPT_DIR}"/[0-9][0-9]-*.sh; do
    name="$(basename "${check}")"
    printf -- '--- %s\n' "${name}" >&2
    if bash "${check}"; then
        PASSED=$((PASSED + 1))
    else
        FAILED+=("${name}")
    fi
    printf '\n' >&2
done

if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '%sFAILED%s %d check(s):\n' "${C_FAIL}" "${C_OFF}" "${#FAILED[@]}" >&2
    for name in "${FAILED[@]}"; do printf '  - %s\n' "${name}" >&2; done
    printf '\nDownloads kept in %s for inspection.\n' "${WORKDIR}" >&2
    exit 1
fi

printf '%sAll %d checks passed.%s\n' "${C_PASS}" "${PASSED}" "${C_OFF}" >&2
printf 'Downloads cached in %s (safe to delete).\n' "${WORKDIR}" >&2
