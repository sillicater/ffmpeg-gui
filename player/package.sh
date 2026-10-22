#!/bin/zsh
# 生成仅播放器的安装包（拖入 Applications 即可，不包含 Electron 主程序）
set -e
cd "$(dirname "$0")"
APP=build/Player.app
STAGE=build/dmg
OUT=../dist/多媒体工具播放器-1.0.0.dmg
NAME=多媒体工具播放器.app

[[ -d "$APP" ]] || { echo "缺少 $APP，请先运行 bash build.sh"; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE" ../dist
cp -R "$APP" "$STAGE/$NAME"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/使用说明.txt" <<'TXT'
多媒体工具播放器

安装：把「多媒体工具播放器.app」拖进 Applications 文件夹。

设为默认打开方式：
  打开播放器 → 菜单栏「文件」→「设为默认媒体播放器…」。
  之后双击视频、音频、图片会直接由本播放器打开，不再启动 Electron 主程序。

依赖：播放器使用系统里已安装的 libmpv（Homebrew）：
  brew install mpv
TXT
rm -f "$OUT"
hdiutil create -quiet -volname "多媒体工具播放器" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
