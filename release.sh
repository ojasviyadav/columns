#!/bin/zsh
# Makes the public download: dist/Columns-<version>.dmg, signed with a Developer ID, notarized by Apple and stapled,
# with its SHA-256 beside it. Needs a "Developer ID Application" certificate in the keychain and a notary profile
# (xcrun notarytool store-credentials <profile> --apple-id … --team-id …).
#   NOTARY_PROFILE=<profile> ./release.sh
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> ./release.sh
set -euo pipefail
cd "${0:A:h}"
: "${NOTARY_PROFILE:?Name the notary profile: NOTARY_PROFILE=<profile> ./release.sh}"
identity="${SIGN_IDENTITY:-Developer ID Application}"
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or remove the changes first: a release is built from a commit." >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
INSTALL=0 SIGN_IDENTITY="$identity" ./build.sh
mkdir -p dist
dmg="dist/Columns-$version.dmg"
stage=$(mktemp -d)
cp -R build/Columns.app "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -quiet -volname "Columns" -srcfolder "$stage" -format UDZO "$dmg"
rm -rf "$stage"
codesign --force --timestamp --sign "$identity" "$dmg"
# Apple checks the disk image and everything in it; the ticket is then stapled to it, so it opens offline too.
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
(cd dist && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
echo "Made $dmg"; cat "$dmg.sha256"
