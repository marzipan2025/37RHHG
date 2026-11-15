#!/bin/zsh
# libspaces.dylib(universal) 만들기. 결과는 저장소에 넣는다(빌드 맥에 Xcode 명령행 도구만 있으면 됨).
set -e
cd "$(dirname "$0")"
clang -dynamiclib -fobjc-arc -framework Cocoa -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -o libspaces.dylib spaces.m
echo "완료: $(pwd)/libspaces.dylib"
