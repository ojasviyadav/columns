#!/bin/zsh
# Builds Columns.app and installs it into ~/Applications.  Usage: ./build.sh
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh   signs for distribution (default: ad hoc)
#   INSTALL=0 ./build.sh                                      builds build/Columns.app without installing it
#   CHECK_COPY=1 ./build.sh                                   builds build/Columns Check.app for checks/ (its own id and settings,
#                                                             with the hooks the checks use), without installing it
set -euo pipefail
cd "${0:A:h}"
[[ "${CHECK_COPY:-0}" == "1" ]] && { APP_NAME="Columns Check"; BUNDLE_ID=org.learningharness.columns.check; INSTALL=0; }
name="${APP_NAME:-Columns}"
app="build/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# The page's own script must parse (when Node is installed): a syntax error would leave every page blank.
if command -v node >/dev/null; then
  js=$(mktemp -t columns-page).js
  python3 -c 'import re,sys; s=open("Resources/index.html").read(); print(max(re.findall(r"<script(?![^>]*src)[^>]*>(.*?)</script>", s, re.S), key=len))' > "$js"
  node --check "$js" || { echo "Resources/index.html: the page script does not parse" >&2; rm -f "$js"; exit 1; }
  rm -f "$js"
fi
flags=(); [[ "${CHECK_COPY:-0}" == "1" ]] && flags=(-D CHECK_COPY)  # the hooks of checks/ exist only in the check copy
# One app for Apple silicon and Intel Macs: each is compiled on its own, then the two are joined.
tmp=$(mktemp -d)
for arch in arm64 x86_64; do
  swiftc -O -swift-version 6 -target $arch-apple-macos14.2 "${flags[@]}" main.swift Settings.swift Sidebar.swift -o "$tmp/Columns-$arch"
done
lipo -create "$tmp/Columns-arm64" "$tmp/Columns-x86_64" -output "$app/Contents/MacOS/Columns"
rm -rf "$tmp"
cp Info.plist "$app/Contents/"
[[ -n "${BUNDLE_ID:-}" ]] && plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$app/Contents/Info.plist"
cp Resources/* "$app/Contents/Resources/"
identity="${SIGN_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then codesign --force --sign - "$app"
else codesign --force --options runtime --timestamp --sign "$identity" "$app"; fi
[[ "${INSTALL:-1}" == "0" ]] && { echo "Built $app"; exit 0; }
mkdir -p ~/Applications
rm -rf ~/Applications/"$name.app"
cp -R "$app" ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"$name.app"
echo "Installed ~/Applications/$name.app"
