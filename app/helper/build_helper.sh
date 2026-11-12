#!/bin/zsh
# winwatch 도우미를 universal 바이너리로 만든다. 결과: helper/winwatch
set -e
cd "$(dirname "$0")"
swiftc -O -target arm64-apple-macos11 winwatch.swift -o /tmp/winwatch-arm64
swiftc -O -target x86_64-apple-macos11 winwatch.swift -o /tmp/winwatch-x86_64
lipo -create /tmp/winwatch-arm64 /tmp/winwatch-x86_64 -output winwatch
rm -f /tmp/winwatch-arm64 /tmp/winwatch-x86_64
