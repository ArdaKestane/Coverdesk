#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

COVERDESK_UNIVERSAL=1 "$root/scripts/package-app.sh"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$root/Support/Info.plist")"
app="$root/build/Coverdesk.app"
final="$root/build/Coverdesk-${version}.dmg"
zip="$root/build/Coverdesk-${version}.zip"
rw="$root/build/Coverdesk-rw.dmg"
mount="/Volumes/Coverdesk"

if [[ -d "$mount" ]]; then
  hdiutil detach "$mount" -force >/dev/null || true
fi
rm -f "$rw" "$final"

size_kb=$(du -sk "$app" | awk '{print $1}')
size_mb=$((size_kb / 1024 + 32))

hdiutil create -size "${size_mb}m" -fs HFS+ -volname Coverdesk -ov "$rw" >/dev/null
attached=$(hdiutil attach -readwrite -noverify -noautoopen "$rw")
device=$(echo "$attached" | awk 'NR==1 {print $1}')
volume=$(echo "$attached" | awk 'END {print $NF}')

cleanup() {
  if [[ -d "$volume" ]]; then
    hdiutil detach "$device" -force >/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$volume/.background"
swift "$root/scripts/make-dmg-background.swift" "$volume/.background/background.png"
cp -R "$app" "$volume/Coverdesk.app"
ln -s /Applications "$volume/Applications"
cp "$app/Contents/Resources/AppIcon.icns" "$volume/.VolumeIcon.icns"
SetFile -a C "$volume"

osascript <<EOF
tell application "Finder"
  tell disk "Coverdesk"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 880, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Coverdesk.app" of container window to {180, 180}
    set position of item "Applications" of container window to {500, 180}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

rm -rf "$volume/.fseventsd" "$volume/.Trashes"
sync
hdiutil detach "$device" >/dev/null
trap - EXIT

hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -o "$final" >/dev/null
rm -f "$rw"
xattr -cr "$final"

stage="$(mktemp -d)"
ditto "$app" "$stage/Coverdesk.app"
cat > "$stage/Nasıl Açılır.txt" <<'EOF'
Coverdesk'i Uygulamalar klasörüne taşıyın.

İlk açılışta macOS, geliştiricinin doğrulanamadığını söyleyebilir.
Uygulamaya sağ tıklayıp Aç deyin.
Olmazsa Sistem Ayarları > Gizlilik ve Güvenlik bölümünden Yine de Aç'ı seçin.
EOF
rm -f "$zip"
ditto -c -k --norsrc "$stage" "$zip"
rm -rf "$stage"
xattr -cr "$zip"

echo "Built $final"
echo "Built $zip"
