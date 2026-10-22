// imgtool：用 ImageIO / Core Image 转换图片。
// 相比 ffmpeg，能正确解码分块 HEIC 的完整画面，并支持 8/10/16 位输出、
// HDR 增益图展开、缩放和 EXIF/GPS 保留。
//
// 用法：
//   imgtool <输入> <输出> --format jpg --quality 85 --depth 8
//           --hdr auto|keep|sdr --resize keep|width|height|long|percent|custom
//           --width N --height N --percent N --metadata 1|0

import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

func die(_ msg: String) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(1)
}

let argv = CommandLine.arguments
guard argv.count >= 3 else {
  die("用法: imgtool <输入> <输出> [--format jpg] [--quality 0-100] [--depth 8|10|16] ...")
}
let input = URL(fileURLWithPath: argv[1])
let output = URL(fileURLWithPath: argv[2])

var opt: [String: String] = [:]
var i = 3
while i < argv.count {
  let a = argv[i]
  if a.hasPrefix("--"), i + 1 < argv.count {
    opt[String(a.dropFirst(2))] = argv[i + 1]
    i += 2
  } else {
    i += 1
  }
}

let format = (opt["format"] ?? output.pathExtension).lowercased()
let quality = min(100, max(0, Double(opt["quality"] ?? "85") ?? 85))
var depth = Int(opt["depth"] ?? "8") ?? 8
let hdrMode = opt["hdr"] ?? "auto"
let resizeMode = opt["resize"] ?? "keep"
let widthArg = Double(opt["width"] ?? "") ?? 0
let heightArg = Double(opt["height"] ?? "") ?? 0
let percentArg = Double(opt["percent"] ?? "") ?? 0
let keepMetadata = (opt["metadata"] ?? "1") != "0"

let utiNames: [String: String] = [
  "jpg": "public.jpeg", "jpeg": "public.jpeg",
  "png": "public.png", "tif": "public.tiff", "tiff": "public.tiff",
  "heic": "public.heic", "heif": "public.heic",
  "avif": "public.avif",
  "bmp": "com.microsoft.bmp", "gif": "com.compuserve.gif",
]
guard let utiName = utiNames[format], let uti = UTType(utiName) else {
  die("不支持的输出格式: \(format)")
}

// JPG/BMP/GIF 只支持 8bit；AVIF/HEIC 支持 8/10bit；PNG/TIFF 支持 8/16bit
let lossy = ["jpg", "jpeg", "heic", "avif"].contains(format)
switch format {
case "jpg", "jpeg", "bmp", "gif": depth = 8
case "heic", "avif": depth = depth <= 8 ? 8 : 10
default: depth = depth <= 8 ? 8 : 16
}

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
  die("无法读取输入图片: \(input.path)")
}
let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

var decoded: CIImage?
if #available(macOS 14.0, *) {
  // 展开 iPhone HEIC 的 HDR 增益图；普通图片会原样返回
  decoded = CIImage(contentsOf: input, options: [.expandToHDR: true])
}
if decoded == nil { decoded = CIImage(contentsOf: input) }
guard var image = decoded else { die("无法解码图片: \(input.path)") }

let sourceCS = image.colorSpace
let sourceCSName = sourceCS?.name as String? ?? ""
let isHDR = sourceCSName.contains("PQ") || sourceCSName.contains("HLG") || sourceCSName.contains("2100")
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? sRGB

let canKeepHDR = isHDR && depth > 8 && ["png", "tiff", "heic", "avif"].contains(format)
let keepHDR: Bool
switch hdrMode {
case "keep": keepHDR = canKeepHDR
case "sdr": keepHDR = false
default: keepHDR = canKeepHDR
}
// HDR 转 SDR 时用 Display P3 保留宽色域；其它情况沿用原色彩空间
let outCS: CGColorSpace = (isHDR && !keepHDR) ? p3 : (sourceCS ?? sRGB)

// —— 缩放 ——
func even(_ v: Double) -> Double { max(1, (v / 2).rounded() * 2) }
let ext = image.extent
guard ext.width > 0, ext.height > 0 else { die("图片尺寸无效") }
var targetW = ext.width
var targetH = ext.height
switch resizeMode {
case "width":
  if widthArg > 0 {
    targetW = widthArg
    targetH = ext.height * widthArg / ext.width
  }
case "height":
  if heightArg > 0 {
    targetH = heightArg
    targetW = ext.width * heightArg / ext.height
  }
case "long":
  let v = widthArg > 0 ? widthArg : heightArg
  if v > 0 {
    let scale = v / max(ext.width, ext.height)
    targetW = ext.width * scale
    targetH = ext.height * scale
  }
case "percent":
  if percentArg > 0 {
    let scale = percentArg / 100
    targetW = ext.width * scale
    targetH = ext.height * scale
  }
case "custom":
  if widthArg > 0 && heightArg > 0 {
    targetW = widthArg
    targetH = heightArg
  } else if widthArg > 0 {
    targetW = widthArg
    targetH = ext.height * widthArg / ext.width
  } else if heightArg > 0 {
    targetH = heightArg
    targetW = ext.width * heightArg / ext.height
  }
default:
  break
}
targetW = even(targetW)
targetH = even(targetH)

if abs(targetW - ext.width) > 0.5 || abs(targetH - ext.height) > 0.5 {
  if resizeMode == "custom" && widthArg > 0 && heightArg > 0 {
    // 自定义宽高：允许非等比缩放
    image = image.transformed(by: CGAffineTransform(scaleX: targetW / ext.width, y: targetH / ext.height))
  } else {
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(targetW / ext.width, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    if let scaled = filter.outputImage { image = scaled }
  }
}

// 把画面搬到 (0,0)，并裁到整数像素
let moved = image.extent
let normalized = image.transformed(by: CGAffineTransform(translationX: -moved.origin.x, y: -moved.origin.y))
let outW = Int(targetW.rounded())
let outH = Int(targetH.rounded())
let outRect = CGRect(x: 0, y: 0, width: outW, height: outH)
let ciFormat: CIFormat = depth > 8 ? .RGBA16 : .RGBA8
let context = CIContext()
guard let cg = context.createCGImage(normalized, from: outRect, format: ciFormat, colorSpace: outCS) else {
  die("渲染失败")
}

// —— 输出 ——
guard let dest = CGImageDestinationCreateWithURL(output as CFURL, uti.identifier as CFString, 1, nil) else {
  die("无法创建输出文件: \(output.path)")
}
var props: [CFString: Any] = [:]
props[kCGImagePropertyOrientation] = 1
props[kCGImagePropertyPixelWidth] = outW
props[kCGImagePropertyPixelHeight] = outH
props[kCGImagePropertyDepth] = depth
if lossy { props[kCGImageDestinationLossyCompressionQuality] = quality / 100.0 }

if keepMetadata {
  for (k, v) in sourceProps { props[k] = v }
  // 覆盖尺寸/方向，避免旋转两次或尺寸对不上
  props[kCGImagePropertyOrientation] = 1
  props[kCGImagePropertyPixelWidth] = outW
  props[kCGImagePropertyPixelHeight] = outH
  props[kCGImagePropertyDepth] = depth
  if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
    tiff[kCGImagePropertyTIFFOrientation] = 1
    props[kCGImagePropertyTIFFDictionary] = tiff
  }
  if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
    exif[kCGImagePropertyExifPixelXDimension] = outW
    exif[kCGImagePropertyExifPixelYDimension] = outH
    props[kCGImagePropertyExifDictionary] = exif
  }
}
CGImageDestinationAddImage(dest, cg, props as CFDictionary)
guard CGImageDestinationFinalize(dest) else { die("写入失败: \(output.path)") }
