#!/bin/bash
#
# Proves: the artifact is signed exactly the way it is *labelled* — ad-hoc, with no Developer ID
# signature and no notarization.
#
# This is not a check that the build is secure; it is a check that the description is true. The
# download is named "unsigned", the README and release notes tell people to expect a Gatekeeper
# warning and to use right-click -> Open. If a future build were signed or notarized but still
# shipped under that labelling — or, worse, were labelled as signed while carrying only an ad-hoc
# signature — the honesty of the whole release page would be wrong. This check fails in both
# directions.
#
# What it asserts:
#   * the bundle carries a valid ad-hoc signature (`Signature=adhoc`), so it is not tampered with
#     or unsigned-and-broken;
#   * there is no Developer ID authority and no Team Identifier;
#   * Gatekeeper does not accept it for execution, i.e. it is not notarized.
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
CHECK_NAME="signing-honesty"
parse_common_args "$@"

require_tool codesign
ensure_app

# --- the signature that is there is intact -------------------------------------------------------
codesign --verify --strict --verbose=2 "${APP_PATH}" >/dev/null 2>&1 \
    || fail "the bundle does not pass strict signature verification; the download may be damaged or modified"

INFO="$(codesign --display --verbose=4 "${APP_PATH}" 2>&1 || true)"

# --- ad-hoc, not Developer ID --------------------------------------------------------------------
printf '%s\n' "${INFO}" | grep -q 'Signature=adhoc' \
    || fail "expected an ad-hoc signature, but codesign reports:
$(printf '%s\n' "${INFO}" | grep -E 'Signature|Authority|TeamIdentifier' || printf '%s' "${INFO}")"

if printf '%s\n' "${INFO}" | grep -qi 'Authority=Developer ID'; then
    fail "the bundle carries a Developer ID signature, but the release labels it as unsigned ad-hoc"
fi

TEAM="$(printf '%s\n' "${INFO}" | grep -E '^TeamIdentifier=' | head -n 1 || true)"
case "${TEAM}" in
    ""|"TeamIdentifier=not set") ;;
    *) fail "expected no Team Identifier on an ad-hoc build, found: ${TEAM}" ;;
esac

# --- not notarized -------------------------------------------------------------------------------
# spctl assesses the signature itself; an ad-hoc build must be rejected. A build that Gatekeeper
# accepts for execution is notarized, which the release does not claim.
if command -v spctl >/dev/null 2>&1; then
    ASSESS="$(spctl --assess --type execute --verbose=4 "${APP_PATH}" 2>&1 || true)"
    if printf '%s\n' "${ASSESS}" | grep -qi 'accepted'; then
        fail "Gatekeeper accepts this build for execution, so it is signed/notarized — but the
release labels it as unsigned and un-notarized. spctl said:
${ASSESS}"
    fi
    if printf '%s\n' "${ASSESS}" | grep -qi 'Notarized'; then
        fail "spctl reports a notarized build, which contradicts the release labelling:
${ASSESS}"
    fi
    log "spctl (expected to reject): $(printf '%s' "${ASSESS}" | tr '\n' ' ')"
else
    log "spctl not available; skipped the notarization assertion"
fi

pass "signature matches the labelling: ad-hoc, no Developer ID, no notarization"
pass "users should expect the documented Gatekeeper warning and right-click -> Open on first launch"
