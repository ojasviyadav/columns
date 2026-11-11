#!/bin/zsh
# Builds Resources/AppIcon.icns from icon.swift. Usage: icon/make-icns.sh <A|B|C>
# 16 and 32 px use the simplified art (three solid columns); larger sizes use the full drawing.
set -euo pipefail
cd "$(dirname "$0")"
v="${1:?variant A, B or C}"
tmp="$(mktemp -d)"; set="$tmp/AppIcon.iconset"; mkdir "$set"
swiftc -O icon.swift -o "$tmp/icon"
"$tmp/icon" "$v" "$tmp/full.png"
"$tmp/icon" "$v" "$tmp/small.png" small
for s in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((s * scale)); src="$tmp/full.png"; (( px <= 32 )) && src="$tmp/small.png"
    name="icon_${s}x${s}.png"; (( scale == 2 )) && name="icon_${s}x${s}@2x.png"
    sips -z $px $px "$src" --out "$set/$name" >/dev/null
  done
done
iconutil -c icns "$set" -o ../Resources/AppIcon.icns
rm -rf "$tmp"
echo "Resources/AppIcon.icns ($v)"
