#!/usr/bin/env bash
set -euo pipefail

CHIRP_RUN_MODE="${1:-run}"
case "$CHIRP_RUN_MODE" in
  run|--debug|--logs|--telemetry|--verify|--design-preview|--attachment-transfer-preview|--identity-setup-preview) ;;
  *) echo "usage: $0 [--debug|--logs|--telemetry|--verify|--design-preview|--attachment-transfer-preview|--identity-setup-preview]" >&2; exit 2 ;;
esac

CHIRP_BUILD_CONFIGURATION=Release
CHIRP_APP_NAME=Chirp.app
if [[ "$CHIRP_RUN_MODE" == --design-preview ]]; then
  CHIRP_BUILD_CONFIGURATION=Debug
  CHIRP_APP_NAME=Chirp-DesignPreview.app
fi
if [[ "$CHIRP_RUN_MODE" == --attachment-transfer-preview ]]; then
  CHIRP_BUILD_CONFIGURATION=Debug
  CHIRP_APP_NAME=Chirp-AttachmentPreview.app
fi
if [[ "$CHIRP_RUN_MODE" == --identity-setup-preview ]]; then
  CHIRP_BUILD_CONFIGURATION=Debug
  CHIRP_APP_NAME=Chirp-IdentityPreview.app
fi

CHIRP_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CHIRP_ROOT_DIR"
if [[ "$CHIRP_RUN_MODE" == --identity-setup-preview ]]; then
  CHIRP_PREVIEW_EXECUTABLE="$CHIRP_ROOT_DIR/Client/apple/dist/macos/$CHIRP_APP_NAME/Contents/MacOS/Chirp"
  while IFS= read -r candidate; do
    if [[ "$(ps -ww -p "$candidate" -o comm=)" == "$CHIRP_PREVIEW_EXECUTABLE" ]]; then
      kill "$candidate" >/dev/null 2>&1 || true
    fi
  done < <(pgrep -x Chirp || true)
else
  pkill -x Chirp >/dev/null 2>&1 || true
fi

# Reapply all SDK patches even when an older Vendor checkout exists.
python3 scripts/prepare-livekit-swift.py
python3 scripts/prepare-rnnoise.py
# Cargo's incremental build checks the current lockfile and Rust toolchain.
# An existing XCFramework alone does not prove its dependencies are current.
sh scripts/prepare-mls.sh

mkdir -p .build Client/apple/dist/macos
CHIRP_SIGNING_OPTIONS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO)
if [[ -n "${CHIRP_MACOS_TEAM_ID:-}" ]]; then
  CHIRP_SIGNING_OPTIONS=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
    CODE_SIGN_STYLE=Automatic "CODE_SIGN_IDENTITY=Apple Development"
    "DEVELOPMENT_TEAM=$CHIRP_MACOS_TEAM_ID" ENABLE_HARDENED_RUNTIME=YES)
  if [[ "$CHIRP_RUN_MODE" == --attachment-transfer-preview ]]; then
    CHIRP_SIGNING_OPTIONS+=(PRODUCT_BUNDLE_IDENTIFIER=cn.youzifeile.chirp.attachment-preview)
  fi
else
  # Offline ad-hoc previews cannot authorize a team-scoped keychain group.
  python3 - <<'PY'
from pathlib import Path
import plistlib
source = Path('Client/apple/macOS/Chirp.entitlements')
entitlements = plistlib.loads(source.read_bytes())
entitlements.pop('keychain-access-groups', None)
Path('.build/macos-adhoc.entitlements').write_bytes(plistlib.dumps(entitlements))
PY
  CHIRP_SIGNING_OPTIONS+=("CODE_SIGN_ENTITLEMENTS=$CHIRP_ROOT_DIR/.build/macos-adhoc.entitlements")
fi
if [[ "$CHIRP_RUN_MODE" == --identity-setup-preview ]]; then
  CHIRP_SIGNING_OPTIONS+=(PRODUCT_BUNDLE_IDENTIFIER=cn.youzifeile.chirp.identity-preview)
fi
if ! xcodebuild -quiet -project Client/apple/Chirp.xcodeproj -scheme Chirp-macOS \
  -configuration "$CHIRP_BUILD_CONFIGURATION" -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath .build/DerivedData-mac -clonedSourcePackagesDirPath .build/apple-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ONLY_ACTIVE_ARCH=YES "${CHIRP_SIGNING_OPTIONS[@]}" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  build > .build/macos-build-run.log 2>&1; then
  tail -n 60 .build/macos-build-run.log >&2
  exit 1
fi

CHIRP_APP_BUNDLE="$CHIRP_ROOT_DIR/Client/apple/dist/macos/$CHIRP_APP_NAME"
rm -rf "$CHIRP_APP_BUNDLE"
ditto ".build/DerivedData-mac/Build/Products/$CHIRP_BUILD_CONFIGURATION/Chirp.app" "$CHIRP_APP_BUNDLE"
if [[ "$CHIRP_RUN_MODE" == --attachment-transfer-preview && -z "${CHIRP_MACOS_TEAM_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cn.youzifeile.chirp.attachment-preview' "$CHIRP_APP_BUNDLE/Contents/Info.plist"
fi
# This entrypoint creates local, ad-hoc builds without an Apple Team ID. Library
# validation cannot match their embedded frameworks to a signing team. Explicitly
# clear the runtime flag here, including a flag retained by an incremental build.
# Certificate-signed builds keep Hardened Runtime enabled in the Xcode project.
if [[ -z "${CHIRP_MACOS_TEAM_ID:-}" ]]; then
  codesign --force --sign - --options 0 --timestamp=none \
    --preserve-metadata=entitlements "$CHIRP_APP_BUNDLE"
fi
codesign --verify --deep --strict "$CHIRP_APP_BUNDLE"

if [[ "$CHIRP_RUN_MODE" == --debug ]]; then
  exec lldb -- "$CHIRP_APP_BUNDLE/Contents/MacOS/Chirp"
fi
if [[ "$CHIRP_RUN_MODE" == --design-preview || "$CHIRP_RUN_MODE" == --attachment-transfer-preview || "$CHIRP_RUN_MODE" == --identity-setup-preview ]]; then
  /usr/bin/open -n "$CHIRP_APP_BUNDLE" --args "$CHIRP_RUN_MODE" "${@:2}"
  exit 0
fi
/usr/bin/open -n "$CHIRP_APP_BUNDLE"
case "$CHIRP_RUN_MODE" in
  --logs) exec /usr/bin/log stream --info --style compact --predicate 'process == "Chirp"' ;;
  --telemetry) exec /usr/bin/log stream --info --style compact --predicate 'subsystem == "cn.youzifeile.chirp"' ;;
  --verify)
    CHIRP_LAUNCHED_PID=
    for ((attempt = 0; attempt < 40; attempt++)); do
      while IFS= read -r candidate; do
        if [[ "$(ps -ww -p "$candidate" -o comm=)" == "$CHIRP_APP_BUNDLE/Contents/MacOS/Chirp" ]]; then
          CHIRP_LAUNCHED_PID="$candidate"
          break
        fi
      done < <(pgrep -x Chirp || true)
      [[ -n "$CHIRP_LAUNCHED_PID" ]] && break
      sleep 0.25
    done
    if [[ -z "$CHIRP_LAUNCHED_PID" ]]; then
      echo 'Chirp did not start. Check ~/Library/Logs/DiagnosticReports/Chirp-*.ips.' >&2
      exit 1
    fi
    for ((attempt = 0; attempt < 40; attempt++)); do
      if ! kill -0 "$CHIRP_LAUNCHED_PID" 2>/dev/null || \
        [[ "$(ps -ww -p "$CHIRP_LAUNCHED_PID" -o comm=)" != "$CHIRP_APP_BUNDLE/Contents/MacOS/Chirp" ]]; then
        echo 'Chirp exited during launch verification. Check ~/Library/Logs/DiagnosticReports/Chirp-*.ips.' >&2
        exit 1
      fi
      sleep 0.25
    done
    echo "Chirp build and launch verified: PID $CHIRP_LAUNCHED_PID stayed running for 10 seconds."
    ;;
esac
