#!/bin/bash
# 构建菜单栏 KeepAwake 工具（本机使用，ad-hoc 签名）
set -e
cd "$(dirname "$0")"

APP="KeepAwake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "编译 Swift…"
swiftc -parse-as-library -O -o "$APP/Contents/MacOS/KeepAwake" KeepAwake.swift

cp Info.plist "$APP/Contents/Info.plist"

# 清除扩展属性并签名（Spotlight 偶发重新打标，重试最多 3 次）
echo "ad-hoc 签名…"
for i in 1 2 3; do
    xattr -cr "$APP"
    if codesign --force -s - "$APP" 2>/dev/null; then
        break
    fi
    [ "$i" = "3" ] && { codesign --force -s - "$APP"; exit 1; }
done

echo "完成：$(pwd)/$APP"
echo "启动：open $APP"
