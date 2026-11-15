#!/bin/zsh
# 릴리스 파일 만들기: build/release/37RHHG-<버전>.dmg (사람이 설치할 것) + 37RHHG-v<버전>.zip (앱 안 업데이트가 받는 것)
# 버전은 app/export_presets.cfg 의 application/short_version. 04DOPL 의 make_dmg.sh 방식(배경 그림 + Finder 창 배치).
set -e
cd "$(dirname "$0")/.."
APP=37RHHG
VERSION=$(sed -n 's/^application\/short_version="\(.*\)"/\1/p' app/export_presets.cfg)
VOL="$APP $VERSION"
OUT=build/release
BG=packaging/dmg_background.png       # 1280×960(@2x) → 창 640×480pt

echo "▶ 1/4 빌드 (v$VERSION)"
zsh app/build_mac.sh >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/$APP.app/Contents/Info.plist)" = "$VERSION" ] || { echo "버전 불일치"; exit 1; }

echo "▶ 2/4 zip(앱 안 업데이트용)"
mkdir -p $OUT
rm -f $OUT/$APP-v$VERSION.zip
ditto -c -k --keepParent build/$APP.app $OUT/$APP-v$VERSION.zip

echo "▶ 3/4 DMG 꾸미기"
TMP=$(mktemp -d)
mkdir -p $TMP/stage/.background
cp -R build/$APP.app $TMP/stage/
ln -s /Applications $TMP/stage/Applications
cp $BG $TMP/stage/.background/background.png
[ -d "/Volumes/$VOL" ] && hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -volname "$VOL" -srcfolder $TMP/stage -fs HFS+ -format UDRW -ov $TMP/temp.dmg >/dev/null
hdiutil attach $TMP/temp.dmg -readwrite -noverify -noautoopen >/dev/null
sleep 2
# 배경 그림의 화살표(가운데 y≈242pt, x 265~375pt) 양쪽에 앱과 응용 프로그램 폴더를 둔다.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 740, 608}   -- 내용 480pt + 제목 막대
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 80
    set text size of opts to 12
    set background picture of opts to file ".background:background.png"
    set position of item "$APP.app" of container window to {190, 242}
    set position of item "Applications" of container window to {450, 242}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync; sleep 2
for i in 1 2 3; do hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 && break || sleep 1; done
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true

echo "▶ 4/4 압축 DMG"
rm -f $OUT/$APP-$VERSION.dmg
hdiutil convert $TMP/temp.dmg -format UDZO -o $OUT/$APP-$VERSION.dmg >/dev/null
rm -rf $TMP
ls -lh $OUT/$APP-$VERSION.dmg $OUT/$APP-v$VERSION.zip
