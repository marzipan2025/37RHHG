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
# 말 도우미를 실행 파일 옆에 둔다.
cp helper/bubble "$OUT/Contents/MacOS/bubble"
# 우클릭 메뉴의 버튼 그림(도우미가 파일로 읽는다).
mkdir -p "$OUT/Contents/Resources/buttons"
cp buttons/*.png "$OUT/Contents/Resources/buttons/"
# Apple Development 인증서가 있으면 그걸로 서명한다. 임시 서명(-)은 빌드마다 서명이 달라져서
# 화면 기록 권한(혼자 돌아다니기의 화면 보기)이 빌드할 때마다 풀린다.
ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}')
codesign --force --deep -s "${ID:--}" "$OUT"
echo "서명: ${ID:-임시}"
codesign -v "$OUT"
echo "완료: $OUT"
