#!/bin/bash
# Notarize and staple build/FastMac.app so Gatekeeper shows the standard
# "downloaded from the Internet" prompt instead of blocking the app.
#
# Build first with a Developer ID certificate:
#   FASTMAC_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/bundle.sh
#
# Then provide notary credentials in one of two ways:
#   • a keychain profile, created once with `xcrun notarytool store-credentials`:
#       FASTMAC_NOTARY_PROFILE=fastmac scripts/notarize.sh
#   • an App Store Connect API key (used by the release workflow):
#       APPLE_API_KEY_PATH=AuthKey.p8 APPLE_API_KEY_ID=… APPLE_API_ISSUER_ID=… scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/FastMac.app"
[ -d "$APP" ] || { echo "No $APP. Run scripts/bundle.sh first." >&2; exit 1; }
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "$APP isn't signed with a Developer ID Application certificate." >&2
  echo "Rebuild with FASTMAC_SIGNING_IDENTITY set; ad-hoc builds can't be notarized." >&2
  exit 1
fi

if [ -n "${FASTMAC_NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$FASTMAC_NOTARY_PROFILE")
elif [ -n "${APPLE_API_KEY_PATH:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ] && [ -n "${APPLE_API_ISSUER_ID:-}" ]; then
  AUTH=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
else
  echo "Set FASTMAC_NOTARY_PROFILE, or APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER_ID." >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fastmac-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/FastMac.zip"

echo "Submitting to Apple's notary service (usually a few minutes)…"
xcrun notarytool submit "$WORK/FastMac.zip" "${AUTH[@]}" --wait --output-format json > "$WORK/result.json"
STATUS="$(/usr/bin/plutil -extract status raw "$WORK/result.json" 2>/dev/null || echo unknown)"
ID="$(/usr/bin/plutil -extract id raw "$WORK/result.json" 2>/dev/null || echo unknown)"
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization finished with status: $STATUS (submission $ID). Apple's log:" >&2
  xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
  exit 1
fi

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "notarized $APP"
