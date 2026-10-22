// 把指定 App 设为 macOS 上视频/音频/图片的默认打开方式
// 用法: swift tools/set-defaults.swift "/Applications/多媒体工具.app"
import AppKit
import Foundation
import UniformTypeIdentifiers

guard CommandLine.arguments.count > 1 else {
  print("用法: swift set-defaults.swift <App.app>")
  exit(2)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL

let exts = [
  // 视频
  "mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "flv", "wmv",
  "mpg", "mpeg", "3gp", "ogv", "rmvb", "rm", "asf", "vob",
  // 音频
  "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "wma", "aiff", "aif",
  "ape", "alac", "amr", "mid", "midi",
  // 图片
  "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
  "avif", "ico", "tga", "dds",
]

var types: [UTType] = [.movie, .audio, .image]
var seen = Set(types.map { $0.identifier })
for e in exts {
  guard let t = UTType(filenameExtension: e) else { continue }
  if t.identifier.hasPrefix("dyn.") { continue }   // 动态 UTI 无法作为默认打开方式
  if seen.insert(t.identifier).inserted { types.append(t) }
}

var okCount = 0
var failed: [(String, String)] = []
let sem = DispatchSemaphore(value: 0)

// 逐个设置：并发调用 Launch Services 偶尔会瞬时失败。
// 个别类型在系统里没有可用的处理程序时回调可能永远不来，加超时跳过。
func setNext(_ i: Int) {
  guard i < types.count else { sem.signal(); return }
  let t = types[i]
  var finished = false
  let timeout = DispatchWorkItem {
    guard !finished else { return }
    finished = true
    failed.append((t.identifier, "超时"))
    setNext(i + 1)
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
  NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: t) { error in
    guard !finished else { return }
    finished = true
    timeout.cancel()
    if let error {
      failed.append((t.identifier, error.localizedDescription))
    } else {
      okCount += 1
    }
    setNext(i + 1)
  }
}
setNext(0)

while sem.wait(timeout: .now() + 0.05) == .timedOut {
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

for (id, msg) in failed {
  FileHandle.standardError.write("✗ \(id): \(msg)\n".data(using: .utf8)!)
}
print("已设置 \(okCount)/\(types.count) 种媒体类型")
