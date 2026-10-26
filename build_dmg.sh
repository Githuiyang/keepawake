#!/bin/bash
# Build KeepAwake.app + KeepAwake.dmg (universal, ad-hoc signed)
# 参考 podcast-to-article/scripts/build_macos_dmg.sh 的验证路径
set -e
cd "$(dirname "$0")"

DIST="dist"
APP="KeepAwake.app"

# 1. 编译通用 app
./build.sh

# 2. 图标
python3 create_app_icon.py --iconset /tmp/KeepAwakeIcon.iconset
iconutil -c icns /tmp/KeepAwakeIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || {
    mkdir -p "$APP/Contents/Resources"
    iconutil -c icns /tmp/KeepAwakeIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
}
xattr -cr "$APP" && codesign --force -s - "$APP"

# 3. DMG staging
STAGE=$(mktemp -d -t keepawake-dmg)
COPYFILE_DISABLE=1 cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/先读我 Read Me.txt" << 'TXT'
KeepAwake — 合盖开关（刘海灵动岛式）

安装：
1. 把 KeepAwake.app 拖到右边的 Applications
2. 首次打开：本应用未经 Apple 公证，如被系统拦截，
   打开"终端"执行下面一行后即可正常打开：
   xattr -d com.apple.quarantine /Applications/KeepAwake.app
3. 想免密切换：见 GitHub 仓库 README 的 sudoers 安装器
   https://github.com/Githuiyang/keepawake

MIT License
TXT

# 4. 打包 DMG
mkdir -p "$DIST"
rm -f "$DIST/KeepAwake.dmg"
hdiutil create -volname "KeepAwake" -srcfolder "$STAGE" -ov -format UDZO "$DIST/KeepAwake.dmg"
rm -rf "$STAGE"

echo "Done: $(pwd)/$DIST/KeepAwake.dmg"
