#!/bin/zsh
# Build Crest from this checkout, signed with your own Apple Development
# identity, and install it as /Applications/Crest.app.
#
# Default: the dual-engine app the official release ships (Chromium default,
# WebKit per page), using the prebuilt Chromium engine upstream publishes for
# this checkout's engine inputs. `--webkit` builds the WebKit-only `Crest`
# scheme instead (faster, no engine download).
#
# Differences from the upstream release build:
#   - bundle identifier com.manakkapoor.crest (not com.pauldavis.crest), so it
#     has its own data directory and can coexist with the official app
#   - Personal/Crest-Personal.entitlements: no iCloud/CloudKit, push or
#     passkey entitlements (those belong to the upstream App ID)
#   - Sparkle update checks removed, so the official release can never
#     overwrite this build; updates come from Personal/sync-upstream.sh + this
#
# Usage: Personal/build-mac.sh [--webkit] [--no-install]
#        Personal/build-mac.sh [--webkit] --stage /path/Crest.app
#        Personal/build-mac.sh --install-staged /path/Crest.app
#
# --stage builds and personalizes the app into the given path without
# installing it; --install-staged quits Crest, swaps that app into
# /Applications and opens it. The in-app Software Update uses the pair so a
# build can finish while you keep browsing.
set -euo pipefail

repository_root="${0:A:h:h}"
cd "$repository_root"

team_id="${CREST_PERSONAL_TEAM:-7Y29XS82V8}"
bundle_id="${CREST_PERSONAL_BUNDLE_ID:-com.manakkapoor.crest}"
entitlements="$repository_root/Personal/Crest-Personal.entitlements"
derived_data="${CREST_PERSONAL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Crest-Personal}"
engine_cache_root="${CREST_ENGINE_CACHE:-$HOME/Library/Caches/Crest-local-release}"
application_path="/Applications/Crest.app"
upstream_repository="pauljoda/Crest"
engine=chromium
install=true
stage_path=""
install_staged_path=""
while (( $# )); do
  case "$1" in
    --webkit) engine=webkit ;;
    --no-install) install=false ;;
    --stage) stage_path="${2:A}"; shift ;;
    --install-staged) install_staged_path="${2:A}"; shift ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# Quits the installed Crest if it is running, replaces it with $1 and opens it.
install_application() {
  local source_app="$1"
  local pattern="^${application_path}/Contents/MacOS/"
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    print "==> Quitting Crest"
    osascript -e 'tell application id "'"$bundle_id"'" to quit' 2>/dev/null || true
    for _ in {1..300}; do
      pgrep -f "$pattern" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if pgrep -f "$pattern" >/dev/null 2>&1; then
      print -u2 "Crest did not quit; the installed application was not replaced."
      exit 4
    fi
  fi
  if [[ -e "$application_path" ]]; then
    local existing_id
    existing_id="$(defaults read "$application_path/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    if [[ "$existing_id" != "$bundle_id" ]]; then
      print -u2 "$application_path is a different app ($existing_id). Move it aside first."
      exit 1
    fi
    rm -rf "$application_path"
  fi
  print "==> Installing"
  ditto "$source_app" "$application_path"
  "$lsregister" -f "$application_path" >/dev/null 2>&1 || true
  codesign --verify --deep --strict "$application_path"
  open "$application_path"
}

if [[ -n "$install_staged_path" ]]; then
  [[ -f "$install_staged_path/Contents/Info.plist" ]] || { print -u2 "No staged app at $install_staged_path."; exit 1; }
  [[ "$(defaults read "$install_staged_path/Contents/Info" CFBundleIdentifier)" == "$bundle_id" ]]
  install_application "$install_staged_path"
  rm -rf "$install_staged_path"
  print "Installed and launched $application_path ($(defaults read "$application_path/Contents/Info" CFBundleShortVersionString), staged build)."
  exit 0
fi

# The Xcode build's core phase finds dotnet in PATH, ~/.dotnet or CREST_DOTNET.
export PATH="$HOME/.dotnet:$PATH"
command -v xcodegen >/dev/null || { print -u2 "Install XcodeGen (brew install xcodegen)."; exit 1; }
command -v dotnet  >/dev/null || { print -u2 "Run Scripts/control-plane/install-dotnet.sh first."; exit 1; }

signing_identity="$(security find-identity -v -p codesigning \
  | awk '/Apple Development:/ { print $2; exit }')"
[[ -n "$signing_identity" ]] || { print -u2 "No Apple Development identity in the keychain. Sign in to Xcode > Settings > Accounts and create one."; exit 1; }

version="$(sed -n 's/^MARKETING_VERSION = //p' Config/Version.xcconfig)"
source_commit="$(git rev-parse HEAD)"

staging_root="$(mktemp -d "${TMPDIR%/}/crest-personal.XXXXXX")"
cleanup() {
  find "$staging_root" -depth -delete 2>/dev/null || true
  # Upstream commits Crest.xcodeproj; the regenerated one (which includes the
  # Swift files under Personal/) is a build input only, so the tree stays clean.
  git checkout -q -- Crest.xcodeproj 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
staged_app="$staging_root/Crest.app"

print "==> Generating Xcode project"
xcodegen generate >/dev/null

if [[ "$engine" == webkit ]]; then
  print "==> Building Crest $version (WebKit, Release) for team $team_id as $bundle_id"
  xcodebuild build -quiet \
    -project Crest.xcodeproj \
    -scheme Crest \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_STYLE=Automatic \
    CREST_MAC_BUNDLE_IDENTIFIER="$bundle_id" \
    CREST_MAC_ENTITLEMENTS="Personal/Crest-Personal.entitlements" \
    CREST_PROVISIONING_PROFILE_SPECIFIER=
  built_app="$derived_data/Build/Products/Release/Crest.app"
  [[ -d "$built_app" ]]
  ditto "$built_app" "$staged_app"
  "$lsregister" -u "$built_app" >/dev/null 2>&1 || true
else
  # --- Chromium engine: the published build matching this checkout, cached by tag.
  engine_tag="$(python3 Scripts/control-plane/chromium_engine.py tag)"
  engine_asset="$(python3 Scripts/control-plane/chromium_engine.py asset)"
  engine_path="$engine_cache_root/$engine_tag/Chromium.app"
  if [[ ! -d "$engine_path" ]]; then
    command -v gh >/dev/null || { print -u2 "Install the GitHub CLI to download $engine_tag."; exit 1; }
    print "==> Downloading Chromium engine $engine_tag"
    download_path="$staging_root/engine-download"
    mkdir -p "$download_path"
    gh release download "$engine_tag" --repo "$upstream_repository" \
      --pattern "$engine_asset" --pattern "${engine_asset}.sha256" --dir "$download_path" \
      || { print -u2 "No Chromium engine is published for this checkout ($engine_tag). Build with --webkit until upstream publishes it."; exit 1; }
    (cd "$download_path" && shasum -a 256 -c "${engine_asset}.sha256")
    ditto -x -k "$download_path/$engine_asset" "$download_path/extracted"
    [[ -d "$download_path/extracted/Chromium.app" ]]
    mkdir -p "$engine_cache_root"
    find "$engine_cache_root" -mindepth 1 -maxdepth 1 -name 'chromium-engine-*' -exec rm -rf {} + 2>/dev/null || true
    mv "$download_path/extracted" "$engine_cache_root/$engine_tag"
  fi
  [[ -f "$engine_path/Contents/Info.plist" ]]

  print "==> Building Crest $version (Chromium $engine_tag, Release) for team $team_id as $bundle_id"

  # --- Native core, published the way the release packages it.
  print "==> Publishing the native core"
  (cd CrestCore && dotnet publish src/CrestCore.Native -c Release -r osx-arm64 --nologo -v quiet)
  core_library="$PWD/CrestCore/src/CrestCore.Native/bin/Release/net10.0/osx-arm64/publish/CrestCore.Native.dylib"
  [[ -f "$core_library" ]]

  # --- Native UI framework, unsigned; the packager signs the whole app.
  print "==> Building the Crest interface"
  xcodebuild build -quiet \
    -project Crest.xcodeproj \
    -scheme CrestChromiumUIProduct \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    CURRENT_PROJECT_VERSION=1 \
    CODE_SIGNING_ALLOWED=NO
  ui_framework="$derived_data/Build/Products/Release/CrestChromiumUIProduct.framework"
  [[ -d "$ui_framework" ]]
  for entry in crest_chromium_ui_start crest_native_host_run; do
    nm -gU "$ui_framework/CrestChromiumUIProduct" | grep -q "_${entry}\$" \
      || { print -u2 "CrestChromiumUIProduct does not export $entry."; exit 1; }
  done

  # --- Package and sign everything with your identity (library validation
  # requires one team across the app, the engine and the host framework).
  packaged_app="$staging_root/product/Crest.app"
  print "==> Packaging and signing with the Chromium engine"
  CREST_DEFAULT_UPDATE_CHANNEL=development python3 Scripts/control-plane/package-chromium-host.py \
    --browser "$engine_path" \
    --product \
    --distribution \
    --ui "$ui_framework" \
    --core "$core_library" \
    --entitlements "$entitlements" \
    --signing-identity "$signing_identity" \
    --output "$packaged_app"
  mv "$packaged_app" "$staged_app"
fi

# --- Personal identity: our bundle id, no Sparkle feed. Only the app's own
# Info.plist changes, so only the outer seal is re-signed, keeping the
# entitlements the build applied.
plist="$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CrestAppIconPreferenceDomain $bundle_id" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :SUFeedURL' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$plist"
/usr/libexec/PlistBuddy -c 'Set :SUAutomaticallyUpdate false' "$plist"
# The in-app Software Update rebuilds from this checkout instead of a feed.
/usr/libexec/PlistBuddy -c "Add :CrestSourceCheckout string $repository_root" "$plist"
/usr/libexec/PlistBuddy -c "Add :CrestSourceCommit string $source_commit" "$plist"
/usr/libexec/PlistBuddy -c "Add :CrestSourceEngine string $engine" "$plist"
applied_entitlements="$staging_root/entitlements.plist"
codesign -d --entitlements :- "$staged_app" 2>/dev/null > "$applied_entitlements"
codesign --force --options runtime --timestamp --sign "$signing_identity" \
  --entitlements "$applied_entitlements" "$staged_app"
codesign --verify --deep --strict "$staged_app"
[[ "$(defaults read "$staged_app/Contents/Info" CFBundleIdentifier)" == "$bundle_id" ]]

if [[ -n "$stage_path" ]]; then
  [[ "$stage_path" == *.app ]] || { print -u2 "--stage needs a .app path"; exit 2; }
  rm -rf "$stage_path"; mkdir -p "${stage_path:h}"; ditto "$staged_app" "$stage_path"
  print "Staged $stage_path ($version, $engine, commit ${source_commit[1,8]})."
  exit 0
fi
if [[ "$install" != true ]]; then
  final="$HOME/Desktop/Crest.app"
  rm -rf "$final"; ditto "$staged_app" "$final"
  print "Built $final (not installed)."
  exit 0
fi

install_application "$staged_app"
print "Installed and launched $application_path ($version, $engine, commit ${source_commit[1,8]})."
