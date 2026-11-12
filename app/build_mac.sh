#!/bin/zsh
# 메뉴바 캐릭터 앱을 build/37RHHG.app 으로 내보낸다.
# Dock 아이콘 숨김(LSUIElement)은 export_presets.cfg 의 additional_plist_content 로 들어간다.
set -e
cd "$(dirname "$0")"
OUT=../build/37RHHG.app
rm -rf "$OUT"
mkdir -p ../build
helper/build_helper.sh
godot --headless --path . --import >/dev/null 2>&1 || true
godot --headless --path . --export-release "macOS" "$OUT" 2>&1 | grep -E "ERROR" && exit 1 || true
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$OUT/Contents/Info.plist")" = "true" ] || { echo "LSUIElement 누락"; exit 1; }
# 다른 앱 창 위치를 알려주는 도우미를 실행 파일 옆에 둔다.
cp helper/winwatch "$OUT/Contents/MacOS/winwatch"
cp helper/bubble "$OUT/Contents/MacOS/bubble"
codesign --force --deep -s - "$OUT"
codesign -v "$OUT"
echo "완료: $OUT"
