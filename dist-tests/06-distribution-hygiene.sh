#!/bin/bash
#
# Proves: the shipped bundle contains only the application — nobody's data, nobody's key, and no
# trace of the machine it was built on.
#
# This is the check the release process exists for. A packaged build that carried a developer's
# meeting audio, saved project state, or an API key would be a privacy incident, not a bug. It is
# verified here on the *downloaded* artifact, independently of the build machine, so a reader does
# not have to take the build script's word for it.
#
# What it asserts, inside the extracted bundle:
#   * no persisted user-data files (projects.json, profile.json, agent-*.json, beta-metrics.json,
#     continuity-transitions.json, .env*);
#   * no audio or transcript media of any kind;
#   * nothing that looks like an API key;
#   * no /Users/... or /home/... absolute path left in any shipped file.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="distribution-hygiene"
parse_common_args "$@"

ensure_app

# --- persisted user data -------------------------------------------------------------------------
USER_DATA="$(find "${APP_PATH}" -type f \( \
    -name 'projects.json' -o \
    -name 'profile.json' -o \
    -name 'agent-*.json' -o \
    -name 'beta-metrics.json' -o \
    -name 'continuity-transitions.json' -o \
    -name '.env*' \) 2>/dev/null || true)"
[ -z "${USER_DATA}" ] || fail "the shipped bundle contains persisted user-data files:
${USER_DATA}"

# --- meeting audio and media ---------------------------------------------------------------------
MEDIA="$(find "${APP_PATH}" -type f \( \
    -iname '*.m4a' -o -iname '*.wav' -o -iname '*.mp3' -o -iname '*.webm' -o \
    -iname '*.aac' -o -iname '*.flac' -o -iname '*.caf' -o -iname '*.aiff' -o \
    -iname '*.mp4' -o -iname '*.mov' \) 2>/dev/null || true)"
[ -z "${MEDIA}" ] || fail "the shipped bundle contains audio/video files:
${MEDIA}"

# --- credentials ----------------------------------------------------------------------------------
# Scanned across every shipped file, binaries included, via `strings` so a key compiled into the
# binary cannot hide from a text grep.
SCAN="${STRINGS_CACHE}"
if [ ! -f "${SCAN}" ]; then
    log "scanning every shipped file for embedded text"
    require_tool strings
    find "${APP_PATH}" -type f -print0 \
        | LC_ALL=C xargs -0 -n 20 strings -a 2>/dev/null > "${SCAN}" || true
fi
[ -s "${SCAN}" ] || fail "could not read any text out of the bundle; the hygiene scan is unreliable"

KEYS="$(LC_ALL=C grep -aoE 'sk-(proj|svcacct|admin)?-?[A-Za-z0-9_-]{20,}' "${SCAN}" | sort -u | head -n 5 || true)"
[ -z "${KEYS}" ] || fail "something in the shipped bundle looks like an API key (first matches shown):
${KEYS}"

# --- build-machine paths ---------------------------------------------------------------------------
LOCAL_PATHS="$(LC_ALL=C grep -aoE '/(Users|home)/[A-Za-z0-9._-]+/[A-Za-z0-9._/-]*' "${SCAN}" | sort -u | head -n 10 || true)"
[ -z "${LOCAL_PATHS}" ] || fail "the shipped bundle leaks absolute paths from the build machine (first matches shown):
${LOCAL_PATHS}"

FILE_COUNT="$(find "${APP_PATH}" -type f | wc -l | tr -d ' ')"
pass "no user data, audio, credentials, or build-machine paths in ${FILE_COUNT} shipped files"
