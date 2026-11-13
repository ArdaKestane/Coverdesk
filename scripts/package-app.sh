#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

product_binary() {
  local path="$1"
  if [[ -x "$path/release/Coverdesk" ]]; then
    echo "$path/release/Coverdesk"
  elif [[ -x "$path/out/Products/Release/Coverdesk" ]]; then
    echo "$path/out/Products/Release/Coverdesk"
  else
    return 1
  fi
}

if [[ "${COVERDESK_UNIVERSAL:-0}" == 1 ]]; then
  echo "Building a universal binary (Apple silicon and Intel)..."
  swift build -c release --triple arm64-apple-macosx14.0 --build-path "$root/.build/arm64"
  if swift build -c release --triple x86_64-apple-macosx14.0 --build-path "$root/.build/x86_64"; then
    mkdir -p "$root/build"
    binary="$root/build/Coverdesk"
    lipo -create \
      "$(product_binary "$root/.build/arm64")" \
      "$(product_binary "$root/.build/x86_64")" \
      -output "$binary"
  else
    echo "Intel build failed; the disk image will run on Apple silicon only."
    binary="$(product_binary "$root/.build/arm64")"
  fi
else
  swift build -c release
  binary="$(product_binary "$root/.build")"
fi

app="$root/build/Coverdesk.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/Coverdesk"
cp "$root/Support/Info.plist" "$app/Contents/Info.plist"

icon_png="$root/build/AppIcon.png"
iconset="$root/build/AppIcon.iconset"
swift "$root/scripts/make-icon.swift" "$icon_png"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$icon_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"
echo "Built $app"
