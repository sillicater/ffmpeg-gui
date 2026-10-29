# macOS 轻量极简播放器

macOS 上的轻量极简本地多媒体工具：Swift/libmpv 原生播放器负责视频、音频、图片的查看，Electron 主程序负责批量转码和元数据。

## 功能

- 视频转码：H.264 / HEVC（VideoToolbox 硬编或 libx264/libx265）、AV1、VP9；MP4 / MOV / MKV / WebM 容器；HDR → SDR 色调映射；字幕、章节、faststart。
- 音频转码：MP3、AAC、ALAC、FLAC、WAV、Opus、Vorbis 等；按容器自动限制可选编码。
- 图片转码：ImageIO 完整解码 HEIC/AVIF，支持 8/10/16 位输出、HDR 增益图、EXIF/GPS 元数据保留。
- 元数据查看：ffprobe 原始信息 + exiftool 中文翻译（相机、镜头、GPS、色彩空间等）。
- 原生播放器：libmpv + OpenGL 渲染，HDR/杜比视界 EDR、GIF 动图、缩放/平移、自动隐藏控制条、后台自动暂停。
- 播放时阻止系统/显示器休眠；全屏时鼠标静止自动隐藏。
- 「播放」菜单集中切换音轨和字幕轨；每个文件记住上次关闭时的播放位置、音轨和字幕轨，下次打开自动续播。
- **独立播放器**：可单独安装为 `多媒体工具播放器.app`，直接接管双击打开，不需要 Electron 主程序。

## 下载

从 [Releases](https://github.com/sillicater/macos-minimal-player/releases) 下载：

- `MediaTool-0.1.0-arm64.dmg`：Electron 主程序
- `MediaTool-Player-1.0.0.dmg`：仅播放器

## 环境要求

- macOS 13 或更高版本
- Node.js 18+
- Xcode Command Line Tools（提供 `swiftc`，编译播放器和 imgtool）
- Homebrew：
  ```bash
  brew install ffmpeg mpv
  # 可选：查看 EXIF / GPS
  brew install exiftool
  ```

播放器链接系统的 `libmpv`，因此独立安装包仍需要 Homebrew 的 `mpv`；它不依赖 Electron 主程序。

## 开发

```bash
git clone https://github.com/sillicater/macos-minimal-player.git
cd macos-minimal-player
npm install
npm run build:player     # 编译 Swift 播放器
npm run build:imgtool    # 编译 ImageIO 图片转换工具
npm start                # 启动 Electron 主程序
```

Intel Mac 上编译播放器时指定 Homebrew 前缀：

```bash
MPV_PREFIX=/usr/local npm run build:player
```

## 打包

```bash
npm run dist        # 主程序 DMG（内置播放器）
npm run dist:player # 仅播放器 DMG
```

产物在 `dist/`：

- `多媒体工具-<version>-arm64.dmg`
- `多媒体工具播放器-1.0.0.dmg`

## 仅播放器

1. 打开 DMG，把 `多媒体工具播放器.app` 拖进 Applications。
2. 打开播放器，菜单栏「文件」→「设为默认媒体播放器…」。
3. 之后双击视频、音频、图片会直接由播放器打开。

播放器是单窗口设计：播放中再打开另一个文件会切换当前窗口。首次不带文件启动时会弹出选择文件的对话框。

播放中通过菜单栏「播放」→「音轨 / 字幕」切换轨道。关闭窗口或退出时，播放器会按文件记住当前位置和选中的轨道；下次打开同一文件自动接着播。播放到片尾后进度会归零，下次从头开始。

## 目录结构

```
main.js / preload.js / index.html   Electron 主程序与界面
probe.js / converter.js / exiftool.js / lib.js
player/                             Swift + libmpv 播放器
  main.swift                        AppKit 窗口、HDR、控制条、文件打开
  mpvshim.c / mpvshim.h             libmpv 渲染与事件桥
  build.sh                          编译 Player.app
  package.sh                        生成仅播放器 DMG
tools/imgtool.swift                 ImageIO 图片转换
tools/set-defaults.swift            注册默认打开方式
build/                              图标与构建脚本
```

## 已知限制

- 只支持 macOS；没有 Windows / Linux 版本。
- 播放器一次只显示一个文件。
- 安装包未做 Apple 公证（notarization），自行构建使用。
- 播放器依赖 Homebrew 的 libmpv。

## License

MIT
