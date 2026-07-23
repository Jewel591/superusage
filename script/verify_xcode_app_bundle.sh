#!/usr/bin/env bash
set -euo pipefail

# The app links Sparkle indirectly through SuperUsageCore.framework. Xcode can therefore complete
# the link step even when Sparkle is absent from the final app bundle, but dyld will abort at launch.
# Keep this packaging contract as a build-time assertion so the failure is caught before Run/Archive.

APP_BUNDLE="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${WRAPPER_NAME:?WRAPPER_NAME is required}"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_BINARY="$SPARKLE_FRAMEWORK/Sparkle"

if [[ ! -f "$SPARKLE_BINARY" ]]; then
  echo "error: Sparkle.framework is missing from $APP_BUNDLE/Contents/Frameworks" >&2
  exit 1
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
  if ! /usr/bin/codesign --verify --strict "$SPARKLE_FRAMEWORK"; then
    echo "error: embedded Sparkle.framework has an invalid code signature" >&2
    exit 1
  fi
fi

echo "Verified embedded Sparkle.framework"
