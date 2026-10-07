#!/bin/bash
set -euo pipefail

# Usage: scripts/package-release.sh path/to/Scrobbler.app output-directory 1.2.6
# Build with ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO and ad-hoc signing first.
fail() { printf 'Packaging failed: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 3 ]] || fail "Expected Scrobbler.app, output directory, and release version."
[[ "$(uname -s)" == Darwin ]] || fail "Run this script on macOS."

app_path="$1"
output_directory="$2"
release_version="$3"
repository_directory="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must be MAJOR.MINOR.PATCH."
[[ -d "$app_path" && ! -L "$app_path" && "$(basename "$app_path")" == Scrobbler.app ]] || fail "Expected a Scrobbler.app bundle."
app_path="$(cd "$(dirname "$app_path")" && pwd)/Scrobbler.app"
[[ -f "$repository_directory/distribution/INSTALL.txt" ]] || fail "Missing installation guide."
[[ -f "$repository_directory/LICENSE" ]] || fail "Missing license."

validate_app() {
  local bundle="$1"
  local plist="$bundle/Contents/Info.plist"
  local binary="$bundle/Contents/MacOS/Scrobbler"
  [[ -f "$plist" && -x "$binary" ]] || fail "Missing application metadata or executable."
  /usr/bin/plutil -lint "$plist" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == com.tobybarnes.scrobbler ]] || fail "Unexpected bundle identifier."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" == Scrobbler ]] || fail "Unexpected executable name."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$release_version" ]] || fail "App version does not match release version."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 13.0 ]] || fail "Expected macOS 13.0 minimum."
  /usr/bin/lipo "$binary" -verify_arch arm64 x86_64 || fail "The app must include Apple Silicon and Intel architectures."

  # Fail instead of silently distributing a test build or local developer files.
  local unwanted
  unwanted="$(/usr/bin/find "$bundle" \( -name '*.xctest' -o -name '*.dSYM' -o -name '.git' -o -name 'xcuserdata' -o -name '*.swift' -o -name '*.xcconfig' -o -name '.env*' -o -name 'Secrets.*' -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '*.mobileprovision' \) -print -quit)"
  [[ -z "$unwanted" ]] || fail "Bundle contains test or private developer files."
  /usr/bin/codesign --verify --deep --strict --all-architectures --verbose=2 "$bundle"
  local signature_details
  signature_details="$(/usr/bin/codesign -d --verbose=4 "$bundle" 2>&1)"
  /usr/bin/grep -q '^Signature=adhoc$' <<< "$signature_details" || fail "Expected an ad-hoc signature for this unsigned release."
}

validate_app "$app_path"
mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd)"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/scrobbler-release.XXXXXX")"
mountpoint="$temporary_directory/mounted"
mounted=0
cleanup() {
  if [[ "$mounted" -eq 1 ]]; then
    if ! /usr/bin/hdiutil detach "$mountpoint" -quiet; then
      printf 'Could not detach verification image; temporary files remain at %s\n' "$temporary_directory" >&2
      return
    fi
  fi
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

staging_directory="$temporary_directory/contents"
mkdir -p "$staging_directory" "$mountpoint" "$temporary_directory/zip-check"
/usr/bin/ditto "$app_path" "$staging_directory/Scrobbler.app"
ln -s /Applications "$staging_directory/Applications"
cp "$repository_directory/distribution/INSTALL.txt" "$staging_directory/INSTALL.txt"
cp "$repository_directory/LICENSE" "$staging_directory/LICENSE.txt"
validate_app "$staging_directory/Scrobbler.app"

# Keep these ZIP filenames stable: the in-app updater looks them up by name.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$staging_directory/Scrobbler.app" "$temporary_directory/Scrobbler.zip"
/usr/bin/ditto -x -k "$temporary_directory/Scrobbler.zip" "$temporary_directory/zip-check"
validate_app "$temporary_directory/zip-check/Scrobbler.app"

/usr/bin/hdiutil create -quiet -volname "Scrobbler $release_version" \
  -srcfolder "$staging_directory" -fs HFS+ -format UDZO "$temporary_directory/Scrobbler.dmg"
/usr/bin/hdiutil verify "$temporary_directory/Scrobbler.dmg"
/usr/bin/hdiutil attach "$temporary_directory/Scrobbler.dmg" -readonly -nobrowse -quiet -mountpoint "$mountpoint"
mounted=1
validate_app "$mountpoint/Scrobbler.app"
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]] || fail "DMG is missing the Applications link."
cmp "$repository_directory/distribution/INSTALL.txt" "$mountpoint/INSTALL.txt"
cmp "$repository_directory/LICENSE" "$mountpoint/LICENSE.txt"
/usr/bin/hdiutil detach "$mountpoint" -quiet
mounted=0

(
  cd "$temporary_directory"
  /usr/bin/shasum -a 256 Scrobbler.zip > Scrobbler.zip.sha256
  /usr/bin/shasum -a 256 Scrobbler.dmg > Scrobbler.dmg.sha256
  /usr/bin/shasum -a 256 -c Scrobbler.zip.sha256 Scrobbler.dmg.sha256
)
for asset in Scrobbler.zip Scrobbler.zip.sha256 Scrobbler.dmg Scrobbler.dmg.sha256; do
  mv "$temporary_directory/$asset" "$output_directory/$asset"
done
printf 'Verified Scrobbler %s release assets in %s\n' "$release_version" "$output_directory"
