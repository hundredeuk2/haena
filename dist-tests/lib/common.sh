#!/bin/bash
#
# Shared configuration and helpers for the HAE.NA public distribution tests.
#
# These tests validate a *published release artifact*. They never read, import, or build product
# source, so anyone who can download the release can run them and reach the same verdict.
#
# Every value below is a default that a caller can override, so the same suite works for a future
# release without editing the scripts.
#
# shellcheck shell=bash

set -euo pipefail

# --- defaults: the release under test ------------------------------------------------------------
REPO="${HAENA_REPO:-hundredeuk2/haena}"
TAG="${HAENA_TAG:-v0.2.6-preview.2}"
VERSION="${HAENA_VERSION:-0.2.6}"
BUILD="${HAENA_BUILD:-11}"
ASSET="${HAENA_ASSET:-HAE.NA-${VERSION}-${BUILD}-unsigned.app.zip}"
EXPECTED_SHA256="${HAENA_SHA256:-153cb4a590817fd6580e623d296c1a456e3dd448ede232e28d072a4b4a18bc67}"
# Empty (HAENA_BYTES="" or --bytes "") disables the size assertion, so the `-` form, not `:-`.
EXPECTED_BYTES="${HAENA_BYTES-4244296}"
APP_NAME="${HAENA_APP_NAME:-HAE.NA.app}"
APP_BINARY_NAME="${HAENA_APP_BINARY_NAME:-HAENA}"

# --- defaults: the previous release that must stay untouched -------------------------------------
PRIOR_TAG="${HAENA_PRIOR_TAG:-v0.2.6-preview.1}"
PRIOR_ASSET="${HAENA_PRIOR_ASSET:-HAE.NA-0.2.6-10-unsigned.app.zip}"
PRIOR_SHA256="${HAENA_PRIOR_SHA256:-621dc1e2252f9ff8d0673808364368b007cdcddfd5a7c2dfd563da70e620d287}"

# --- work directory ------------------------------------------------------------------------------
# Downloads and the extracted bundle are cached here so a full run downloads the asset once.
# Never a path inside the repository, and never a hardcoded user path.
WORKDIR="${HAENA_DIST_TEST_WORKDIR:-${TMPDIR:-/tmp}/haena-dist-tests}"

# --- output --------------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_PASS=''; C_FAIL=''; C_DIM=''; C_OFF=''
fi

CHECK_NAME="${CHECK_NAME:-check}"

log()  { printf '%s==>%s %s\n' "${C_DIM}" "${C_OFF}" "$*" >&2; }
pass() { printf '%sPASS%s %s\n' "${C_PASS}" "${C_OFF}" "$*" >&2; }
fail() {
    printf '%sFAIL%s [%s] %s\n' "${C_FAIL}" "${C_OFF}" "${CHECK_NAME}" "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "required tool not found on PATH: $1"
}

usage_common() {
    cat >&2 <<USAGE
Options (all optional; environment variables in parentheses):
  --repo <owner/name>   GitHub repository            (HAENA_REPO)        [${REPO}]
  --tag <tag>           release tag                  (HAENA_TAG)         [${TAG}]
  --version <x.y.z>     CFBundleShortVersionString   (HAENA_VERSION)     [${VERSION}]
  --build <n>           CFBundleVersion              (HAENA_BUILD)       [${BUILD}]
  --asset <file>        release asset file name      (HAENA_ASSET)       [${ASSET}]
  --sha256 <hex>        expected SHA-256             (HAENA_SHA256)
  --bytes <n>           expected byte size           (HAENA_BYTES)       [${EXPECTED_BYTES}]
  --workdir <dir>       download/extract cache       (HAENA_DIST_TEST_WORKDIR)
  --prior-tag <tag>     previous release tag         (HAENA_PRIOR_TAG)   [${PRIOR_TAG}]
  --prior-asset <file>  previous release asset       (HAENA_PRIOR_ASSET) [${PRIOR_ASSET}]
  --prior-sha256 <hex>  previous release SHA-256     (HAENA_PRIOR_SHA256)
  -h, --help            show this help
USAGE
}

parse_common_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo)         REPO="${2:?--repo needs a value}"; shift 2 ;;
            --tag)          TAG="${2:?--tag needs a value}"; shift 2 ;;
            --version)      VERSION="${2:?--version needs a value}"; shift 2 ;;
            --build)        BUILD="${2:?--build needs a value}"; shift 2 ;;
            --asset)        ASSET="${2:?--asset needs a value}"; ASSET_EXPLICIT=1; shift 2 ;;
            --sha256)       EXPECTED_SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
            --bytes)        EXPECTED_BYTES="${2:?--bytes needs a value}"; shift 2 ;;
            --workdir)      WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
            --prior-tag)    PRIOR_TAG="${2:?--prior-tag needs a value}"; shift 2 ;;
            --prior-asset)  PRIOR_ASSET="${2:?--prior-asset needs a value}"; shift 2 ;;
            --prior-sha256) PRIOR_SHA256="${2:?--prior-sha256 needs a value}"; shift 2 ;;
            -h|--help)      usage_common; exit 0 ;;
            *)              printf 'unknown option: %s\n' "$1" >&2; usage_common; exit 2 ;;
        esac
    done
    # --version/--build without an explicit --asset should still name the right file.
    if [ -z "${ASSET_EXPLICIT:-}" ] && [ -z "${HAENA_ASSET:-}" ]; then
        ASSET="HAE.NA-${VERSION}-${BUILD}-unsigned.app.zip"
    fi
}

asset_url()  { printf 'https://github.com/%s/releases/download/%s/%s' "${REPO}" "$1" "$2"; }

# --- anonymous download --------------------------------------------------------------------------
# No token, no `gh`, no netrc, no cookies: this must succeed for a stranger with a plain browser.
# If any of these downloads needs authentication, the release is not actually public and the check
# is supposed to fail.
download_anonymous() {
    local url="$1" dest="$2"
    require_tool curl
    log "downloading (anonymous) ${url}"
    if ! curl --fail --location --silent --show-error \
              --no-netrc --retry 3 --retry-delay 2 --max-time 600 \
              --output "${dest}.partial" "${url}"; then
        rm -f "${dest}.partial"
        return 1
    fi
    mv "${dest}.partial" "${dest}"
}

# Downloads only if a good copy is not already cached in WORKDIR.
fetch_asset() {
    local tag="$1" asset="$2" dest="${WORKDIR}/$2"
    mkdir -p "${WORKDIR}"
    if [ -f "${dest}" ]; then
        log "using cached ${asset}"
        return 0
    fi
    download_anonymous "$(asset_url "${tag}" "${asset}")" "${dest}" \
        || fail "could not anonymously download ${asset} from ${tag} (is the release public?)"
}

fetch_checksum_file() {
    local tag="$1" asset="$2" dest="${WORKDIR}/$2.sha256"
    mkdir -p "${WORKDIR}"
    if [ -f "${dest}" ]; then
        log "using cached ${asset}.sha256"
        return 0
    fi
    download_anonymous "$(asset_url "${tag}" "${asset}.sha256")" "${dest}" \
        || fail "could not anonymously download the published checksum ${asset}.sha256 from ${tag}"
}

sha256_of() {
    require_tool shasum
    shasum -a 256 "$1" | awk '{print $1}'
}

bytes_of() { wc -c < "$1" | tr -d ' '; }

# Extracts the downloaded ZIP once and sets APP_PATH to the extracted bundle.
# A global rather than a command substitution: a `fail` inside `$( )` would only kill the subshell,
# and the caller would carry on with an empty path.
APP_PATH=""
ensure_app() {
    [ -n "${APP_PATH}" ] && return 0
    local zip="${WORKDIR}/${ASSET}" root="${WORKDIR}/extracted"
    local app="${root}/${APP_NAME}"
    if [ ! -d "${app}" ]; then
        require_tool ditto
        [ -f "${zip}" ] || fetch_asset "${TAG}" "${ASSET}"
        rm -rf "${root}"
        mkdir -p "${root}"
        log "extracting ${ASSET}"
        ditto -x -k "${zip}" "${root}" \
            || fail "${ASSET} did not extract cleanly with ditto (damaged archive, or not a zip)"
    fi
    [ -d "${app}" ] || fail "the archive did not expand to ${APP_NAME}; found: $(ls -1 "${root}" 2>/dev/null | tr '\n' ' ')"
    APP_PATH="${app}"
}

app_binary_path() {
    ensure_app
    printf '%s/Contents/MacOS/%s' "${APP_PATH}" "${APP_BINARY_NAME}"
}

# Echoes an Info.plist value, or exits non-zero with a message the caller prints.
plist_value() {
    ensure_app
    local key="$1" plist="${APP_PATH}/Contents/Info.plist"
    [ -f "${plist}" ] || fail "no Info.plist in ${APP_NAME}/Contents"
    /usr/libexec/PlistBuddy -c "Print :${key}" "${plist}" 2>/dev/null || true
}
