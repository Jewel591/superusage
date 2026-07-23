#!/usr/bin/env bash
set -euo pipefail

TEMPLATE="${1:?entitlements template path required}"
PROFILE="${2:?provisioning profile path required}"
OUTPUT="${3:?resolved entitlements output path required}"
CONTAINER_ID="${4:?iCloud container identifier required}"

PROFILE_PLIST="$(mktemp)"
trap 'rm -f "$PROFILE_PLIST"' EXIT
/usr/bin/security cms -D -i "$PROFILE" > "$PROFILE_PLIST"

TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
[ -n "$TEAM_ID" ] || { echo "provisioning profile has no team identifier" >&2; exit 1; }

APP_ID="$(/usr/libexec/PlistBuddy \
  -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
[ -n "$APP_ID" ] || { echo "provisioning profile has no application identifier" >&2; exit 1; }

/usr/libexec/PlistBuddy \
  -c "Print :Entitlements:com.apple.developer.icloud-container-identifiers" "$PROFILE_PLIST" \
  | /usr/bin/grep -Fq "$CONTAINER_ID" \
  || { echo "provisioning profile does not allow $CONTAINER_ID" >&2; exit 1; }

/bin/cp "$TEMPLATE" "$OUTPUT"

# Xcode normally injects these identity entitlements while signing. This repository signs the
# SwiftPM-built bundle directly with codesign, so derive them from the provisioning profile instead.
# Without them taskgated rejects an otherwise valid signature before the app can launch.
/usr/libexec/PlistBuddy \
  -c "Add :com.apple.application-identifier string $APP_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
  -c "Add :keychain-access-groups array" \
  -c "Add :keychain-access-groups:0 string $APP_ID" \
  "$OUTPUT"

# The template must explicitly select Development or Production. A profile can allow both
# environments, but CloudKit custom-zone operations fail when the signed product omits the selected
# environment entitlement.
/usr/bin/plutil -lint "$OUTPUT" >/dev/null
