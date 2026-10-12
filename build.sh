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

# 清除扩展属性，否则 codesign 报 resource fork 错误
xattr -cr "$APP"

echo "ad-hoc 签名…"
codesign --force -s - "$APP"

echo "完成：$(pwd)/$APP"
echo "启动：open $APP"
