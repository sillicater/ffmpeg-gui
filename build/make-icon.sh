#!/bin/zsh
# 由 build/*.svg 生成应用图标
# 用 Electron 离屏渲染，保证背景透明（Quick Look 会加白底，不能用）
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

build() {
  local SVG=$1 OUT=$2
  "$ROOT/node_modules/.bin/electron" render-icon.js "$SVG" "$TMP/master.png" >/dev/null 2>&1
  sips -z 1024 1024 "$TMP/master.png" --out "$TMP/icon1024.png" >/dev/null

  local SET=icon.iconset
  rm -rf "$SET" && mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$OUT"
  rm -rf "$SET"
  echo "built $OUT"
}

build logo.svg icon.icns
build player-logo.svg player-icon.icns
