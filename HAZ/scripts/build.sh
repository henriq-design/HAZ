#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected_developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -z "$selected_developer_dir" || "$selected_developer_dir" == *"/CommandLineTools"* ]]; then
        print -u2 'A full Xcode installation is required.'
        exit 1
    fi
fi
xcodebuild -project "$project_root/HAZ.xcodeproj" -scheme HAZ \
    -configuration Release -destination 'generic/platform=macOS' \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
app_path="$project_root/Build/Release/HAZ.app"
# This app has no bundled third-party executable frameworks. Verify recursively.
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
info="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
[[ "$info" == *'Signature=adhoc'* && "$info" == *'TeamIdentifier=not set'* ]] || {
    print -u2 'Unexpected code-signing identity.'; exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" == 'org.hazapp.HAZ' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app_path/Contents/Info.plist")" == HAZ ]]
print "Local ad-hoc-signed candidate: $app_path"
print 'Not notarized. Do not distribute before validation.'
