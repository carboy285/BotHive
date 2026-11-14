#!/bin/bash
# Produce a universal native .app and a drag-to-Applications DMG on a Mac.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "A Mac with Xcode is required to compile the native app and create its DMG." >&2
  exit 1
fi
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$repo_dir"
output_dir="${1:-$repo_dir/artifacts/macos}"
mkdir -p "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd)"
derived_dir="$output_dir/DerivedData"
identity="${MACOS_SIGN_IDENTITY:--}"
if [[ "$identity" == '-' ]]; then
  echo 'Building an ad-hoc signed local development app (not notarized).'
fi
xcodebuild -project GrokBot.xcodeproj -scheme GrokBotMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_dir" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
  CODE_SIGNING_REQUIRED=YES build
app_path="$derived_dir/Build/Products/Release/OpenGrokBot.app"
if [[ ! -d "$app_path" ]]; then echo "Build did not produce OpenGrokBot.app" >&2; exit 1; fi
codesign --verify --deep --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
image_path="$output_dir/OpenGrokBot-${version}-mac-universal.dmg"
if [[ -e "$image_path" ]]; then echo "Refusing to overwrite $image_path" >&2; exit 1; fi
stage_dir="$(mktemp -d -t opengrokbot-dmg)"
trap 'rm -rf -- "$stage_dir"' EXIT
# ditto preserves the bundle's resources, code signature, and executable modes.
ditto "$app_path" "$stage_dir/OpenGrokBot.app"
ln -s /Applications "$stage_dir/Applications"
# 0.9.9: a window with the Bots around the edges and an arrow to Applications (scripts/make_dmg_background.py).
mkdir "$stage_dir/.background"
tiffutil -cathidpicheck "$script_dir/dmg/background.png" "$script_dir/dmg/background@2x.png" -out "$stage_dir/.background/background.tiff"
rw_image="$stage_dir.rw.dmg"
trap 'rm -rf -- "$stage_dir" "$rw_image"' EXIT
hdiutil create -volname 'OpenGrokBot' -srcfolder "$stage_dir" -format UDRW -ov "$rw_image"
attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "$rw_image")"
device="$(printf '%s\n' "$attach_output" | awk '/\/Volumes\// {print $1; exit}')"
mount_point="$(printf '%s\n' "$attach_output" | grep -o '/Volumes/.*$' | head -n 1)"
volume="${mount_point#/Volumes/}"
if [[ -z "$device" || -z "$volume" ]]; then echo 'Could not find the mounted DMG volume.' >&2; exit 1; fi
# Finder lays out the window. Without a GUI session (some CI runners) this fails and the DMG stays plain.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "OpenGrokBot.app" of container window to {180, 190}
    set position of item "Applications" of container window to {460, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  echo 'Finder could not style the DMG window; continuing with a plain DMG.' >&2
fi
chmod -Rf go-w "$mount_point" || true
sync
hdiutil detach "$device" -quiet || hdiutil detach "$device" -force -quiet
hdiutil convert "$rw_image" -format UDZO -imagekey zlib-level=9 -o "$image_path"
hdiutil verify "$image_path"
if [[ -n "${MACOS_NOTARY_PROFILE:-}" ]]; then
  if [[ "$identity" == '-' ]]; then echo 'Notarization requires a Developer ID identity.' >&2; exit 1; fi
  xcrun notarytool submit "$image_path" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
  xcrun stapler staple "$image_path"
fi
shasum -a 256 "$image_path" > "$image_path.sha256"
printf 'DMG created: %s\n' "$image_path"
