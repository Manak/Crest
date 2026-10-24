#!/bin/zsh
# Build the WebKit composition of Crest from this checkout, signed with your
# own Apple Development identity, and install it as /Applications/Crest.app.
#
# Differences from the upstream release build:
#   - bundle identifier com.manakkapoor.crest (not com.pauldavis.crest), so it
#     has its own data directory and can coexist with the official app
#   - Personal/Crest-Personal.entitlements: no iCloud/CloudKit, push or
#     restricted browser entitlements (those belong to the upstream App ID)
#   - Sparkle update checks removed, so the official release can never
#     overwrite this build; updates come from Personal/sync-upstream.sh + this
#   - WebKit engine only. The Chromium engine needs the separate packaging
#     path in Scripts/install-local-macos-release.sh (see Personal/README.md)
#
# Usage: Personal/build-mac.sh [--no-install]
set -euo pipefail

repository_root="${0:A:h:h}"
cd "$repository_root"

team_id="${CREST_PERSONAL_TEAM:-7Y29XS82V8}"
bundle_id="${CREST_PERSONAL_BUNDLE_ID:-com.manakkapoor.crest}"
entitlements="Personal/Crest-Personal.entitlements"
derived_data="${CREST_PERSONAL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Crest-Personal}"
application_path="/Applications/Crest.app"
install=true
[[ "${1:-}" == "--no-install" ]] && install=false

lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# The Xcode build's core phase finds dotnet in PATH, ~/.dotnet or CREST_DOTNET.
export PATH="$HOME/.dotnet:$PATH"
command -v xcodegen >/dev/null || { print -u2 "Install XcodeGen (brew install xcodegen)."; exit 1; }
command -v dotnet  >/dev/null || { print -u2 "Run Scripts/control-plane/install-dotnet.sh first."; exit 1; }

signing_identity="$(security find-identity -v -p codesigning \
  | awk '/Apple Development:/ { print $2; exit }')"
[[ -n "$signing_identity" ]] || { print -u2 "No Apple Development identity in the keychain. Sign in to Xcode > Settings > Accounts and create one."; exit 1; }

[[ -d Crest.xcodeproj ]] || xcodegen generate >/dev/null

print "Building Crest $(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig) (WebKit, Release) for team $team_id as $bundle_id..."
xcodebuild build -quiet \
  -project Crest.xcodeproj \
  -scheme Crest \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_STYLE=Automatic \
  CREST_MAC_BUNDLE_IDENTIFIER="$bundle_id" \
  CREST_MAC_ENTITLEMENTS="$entitlements" \
  CREST_PROVISIONING_PROFILE_SPECIFIER=

built_app="$derived_data/Build/Products/Release/Crest.app"
[[ -d "$built_app" ]]

# Stage a copy, strip the Sparkle feed, and re-seal the outer bundle. Nested
# helpers keep their signatures; only the app's own Info.plist changed.
staging_root="$(mktemp -d "${TMPDIR%/}/crest-personal.XXXXXX")"
trap 'find "$staging_root" -depth -delete 2>/dev/null || true' EXIT INT TERM HUP
staged_app="$staging_root/Crest.app"
ditto "$built_app" "$staged_app"
plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$plist"
/usr/libexec/PlistBuddy -c 'Set :SUAutomaticallyUpdate false' "$plist"
codesign --force --sign "$signing_identity" \
  --preserve-metadata=entitlements,flags,runtime \
  "$staged_app"
codesign --verify --deep --strict "$staged_app"
[[ "$(defaults read "$staged_app/Contents/Info" CFBundleIdentifier)" == "$bundle_id" ]]

if [[ "$install" != true ]]; then
  final="$HOME/Desktop/Crest.app"
  rm -rf "$final"; ditto "$staged_app" "$final"
  print "Built $final (not installed)."
  exit 0
fi

# Quit a running copy of this build before replacing it.
if pgrep -f "^${application_path}/Contents/MacOS/" >/dev/null 2>&1; then
  osascript -e 'tell application id "'"$bundle_id"'" to quit' 2>/dev/null || true
  for _ in {1..100}; do
    pgrep -f "^${application_path}/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi
if [[ -e "$application_path" ]]; then
  existing_id="$(defaults read "$application_path/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  if [[ "$existing_id" != "$bundle_id" ]]; then
    print -u2 "$application_path is a different app ($existing_id). Move it aside first."
    exit 1
  fi
  rm -rf "$application_path"
fi
ditto "$staged_app" "$application_path"
"$lsregister" -f "$application_path" >/dev/null 2>&1 || true
"$lsregister" -u "$built_app" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$application_path"
open "$application_path"
print "Installed and launched $application_path ($(defaults read "$application_path/Contents/Info" CFBundleShortVersionString), commit $(git rev-parse --short HEAD))."
