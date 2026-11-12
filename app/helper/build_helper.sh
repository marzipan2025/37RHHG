#!/bin/zsh
# 말 도우미(bubble)를 universal 바이너리로 만든다. 결과: helper/bubble
set -e
cd "$(dirname "$0")"
swiftc -O -target arm64-apple-macos11 bubble.swift -o /tmp/bubble-arm64
swiftc -O -target x86_64-apple-macos11 bubble.swift -o /tmp/bubble-x86_64
lipo -create /tmp/bubble-arm64 /tmp/bubble-x86_64 -output bubble
rm -f /tmp/bubble-arm64 /tmp/bubble-x86_64
