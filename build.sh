#!/bin/bash
# Build KeepAwake (universal binary: Apple Silicon + Intel, macOS 13+)
set -e
cd "$(dirname "$0")"

APP="KeepAwake.app"
MACOS_MIN="13.0"

echo "Compiling (universal: arm64 + x86_64, min macOS $MACOS_MIN)…"
swiftc -parse-as-library -O \
    -target "arm64-apple-macosx${MACOS_MIN}" \
    -o KeepAwake.arm64 KeepAwake.swift
swiftc -parse-as-library -O \
    -target "x86_64-apple-macosx${MACOS_MIN}" \
    -o KeepAwake.x86_64 KeepAwake.swift
lipo -create -output KeepAwake.universal KeepAwake.arm64 KeepAwake.x86_64
rm -f KeepAwake.arm64 KeepAwake.x86_64

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mv KeepAwake.universal "$APP/Contents/MacOS/KeepAwake"

cp Info.plist "$APP/Contents/Info.plist"

echo "Ad-hoc codesign (retry up to 3x for Spotlight xattr races)…"
for i in 1 2 3; do
    xattr -cr "$APP"
    if codesign --force -s - "$APP" 2>/dev/null; then
        break
    fi
    [ "$i" = "3" ] && { codesign --force -s - "$APP"; exit 1; }
done

lipo -info "$APP/Contents/MacOS/KeepAwake"
echo "Done: $(pwd)/$APP"
echo "Launch: open $APP   (debug log: KEEPAWAKE_DEBUG=1 open $APP)"
