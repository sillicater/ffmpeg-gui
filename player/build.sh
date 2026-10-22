#!/bin/zsh
# 编译 mpv 播放器，生成 build/Player.app
set -e
cd "$(dirname "$0")"
APP=build/Player.app
MPV_PREFIX=${MPV_PREFIX:-/opt/homebrew}
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp ../build/player-icon.icns $APP/Contents/Resources/AppIcon.icns
clang -O2 -c mpvshim.c -I"$MPV_PREFIX/include" -o build/mpvshim.o
swiftc -O -swift-version 5 main.swift build/mpvshim.o \
  -import-objc-header mpvshim.h \
  -L"$MPV_PREFIX/lib" -lmpv -Xlinker -rpath -Xlinker "$MPV_PREFIX/lib" \
  -framework OpenGL \
  -o $APP/Contents/MacOS/Player
cat > $APP/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>多媒体工具播放器</string>
<key>CFBundleDisplayName</key><string>多媒体工具播放器</string>
<key>CFBundleIdentifier</key><string>local.ffmpeg-gui.player</string>
<key>CFBundleExecutable</key><string>Player</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSMultipleInstancesProhibited</key><true/>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>媒体文件</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Default</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.movie</string>
      <string>public.audio</string>
      <string>public.image</string>
    </array>
  </dict>
</array>
</dict></plist>
PL
codesign -s - --force $APP
echo "built $APP"
