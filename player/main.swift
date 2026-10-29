// 转码工具 · mpv 播放器
// 用 libmpv 解码，通过 render API 把画面画进我们自己的 OpenGL 视图。
// 窗口、标题栏、双击缩放全部交给 AppKit，避开 mpv 自带窗口的缩放 bug。
import AppKit
import Foundation
import OpenGL
import OpenGL.GL
import Metal
import CoreImage
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

struct Session: Decodable {
  let file: String
  let title: String
  let subtitles: [String]?
  let width: Double?
  let height: Double?
  let hdr: Bool?
  let primaries: String?
  let image: Bool?
}

// 独立播放时自己解析文件，不再依赖 Electron 生成的 session.json。
// 有 ffprobe 就用它（和主程序看到的信息一致），没有则退回 AVFoundation/ImageIO。
enum SessionBuilder {
  static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif",
    "heic", "heif", "avif", "ico", "tga", "dds",
  ]

  static let ffprobePath: String? = {
    for p in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
    where FileManager.default.isExecutableFile(atPath: p) {
      return p
    }
    return nil
  }()

  static func make(_ url: URL, completion: @escaping (Session?) -> Void) {
    let ext = url.pathExtension.lowercased()
    if imageExtensions.contains(ext) {
      let size = imageSize(url)
      let s = Session(file: url.path, title: url.lastPathComponent,
                      subtitles: [], width: size.0, height: size.1,
                      hdr: false, primaries: "", image: true)
      DispatchQueue.main.async { completion(s) }
      return
    }
    if let probe = ffprobePath {
      probeFile(probe, url) { probed in
        let s = probed ?? avSession(url)
        DispatchQueue.main.async { completion(s) }
      }
    } else {
      DispatchQueue.global(qos: .userInitiated).async {
        let s = avSession(url)
        DispatchQueue.main.async { completion(s) }
      }
    }
  }

  private static func imageSize(_ url: URL) -> (Double?, Double?) {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
            as? [CFString: Any] else { return (nil, nil) }
    var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
    var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
    let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    if [5, 6, 7, 8].contains(orientation) { swap(&w, &h) }
    return (w, h)
  }

  private static func number(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String { return Double(s) }
    return nil
  }

  private static func probeFile(_ exe: String, _ url: URL,
                                completion: @escaping (Session?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: exe)
      p.arguments = ["-v", "error", "-print_format", "json",
                     "-show_streams", "-show_format", url.path]
      let out = Pipe()
      p.standardOutput = out
      p.standardError = FileHandle.nullDevice
      do { try p.run() } catch { completion(nil); return }
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      guard p.terminationStatus == 0 else { completion(nil); return }
      completion(sessionFromProbe(data, url: url))
    }
  }

  private static func sessionFromProbe(_ data: Data, url: URL) -> Session? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let streams = root["streams"] as? [[String: Any]] else { return nil }
    var width: Double?
    var height: Double?
    var hdr = false
    var primaries = ""
    if let v = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
      var w = number(v["width"])
      var h = number(v["height"])
      var rotation = 0.0
      if let tags = v["tags"] as? [String: Any], let r = number(tags["rotate"]) {
        rotation = r
      }
      var side: [[String: Any]] = []
      if let list = v["side_data_list"] as? [[String: Any]] {
        side = list
        for sd in list {
          if let r = number(sd["rotation"]) { rotation = r }
        }
      }
      // 手机竖拍视频常见 90/270 度旋转，窗口按显示后的方向开
      if abs(abs(rotation.truncatingRemainder(dividingBy: 180)) - 90) < 1 {
        swap(&w, &h)
      }
      width = w
      height = h
      let transfer = (v["color_transfer"] as? String ?? "").lowercased()
      let prim = (v["color_primaries"] as? String ?? "").lowercased()
      let isDolby = side.contains {
        (($0["side_data_type"] as? String) ?? "").lowercased().contains("dovi")
      }
      hdr = transfer == "smpte2084" || transfer == "arib-std-b67" || isDolby
      if !hdr, transfer.isEmpty, prim == "bt2020",
         side.contains(where: {
           (($0["side_data_type"] as? String) ?? "").lowercased().contains("mastering")
         }) {
        hdr = true
      }
      primaries = prim == "smpte432" ? "display-p3" : prim
    }
    return Session(file: url.path, title: url.lastPathComponent,
                   subtitles: [], width: width, height: height,
                   hdr: hdr, primaries: primaries, image: false)
  }

  // 没有 ffprobe 时的原生兜底（MKV 等容器 AVFoundation 可能读不到轨道，
  // 此时窗口按 16:9 开，mpv 仍然能正常播放）
  private static func avSession(_ url: URL) -> Session {
    let asset = AVURLAsset(url: url)
    var width: Double?
    var height: Double?
    var hdr = false
    var primaries = ""
    if let track = asset.tracks(withMediaType: .video).first {
      let size = track.naturalSize.applying(track.preferredTransform)
      let w = abs(size.width)
      let h = abs(size.height)
      if w > 0, h > 0 { width = Double(w); height = Double(h) }
      if let anyFD = track.formatDescriptions.first {
        let fd = anyFD as! CMFormatDescription
        let ext = CMFormatDescriptionGetExtensions(fd) as NSDictionary? as? [String: Any] ?? [:]
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
        let prim = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? ""
        let upper = transfer.uppercased()
        hdr = upper.contains("2084") || upper.contains("HLG")
        if prim.contains("2020") { primaries = "bt2020" }
        else if prim.uppercased().contains("P3") { primaries = "display-p3" }
        if ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil,
           prim.contains("2020") { hdr = true }
      }
    }
    return Session(file: url.path, title: url.lastPathComponent,
                   subtitles: [], width: width, height: height,
                   hdr: hdr, primaries: primaries, image: false)
  }
}

// 把自己设为系统默认媒体打开方式（首次安装/移动 App 后可在菜单里重新执行）
enum DefaultHandlers {
  static let extensions = [
    "mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts", "flv", "wmv",
    "mpg", "mpeg", "3gp", "ogv", "rmvb", "rm", "asf", "vob",
    "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "wma", "aiff", "aif",
    "ape", "alac", "amr", "mid", "midi",
    "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
    "avif", "ico", "tga", "dds",
  ]

  static func types() -> [UTType] {
    var ts: [UTType] = [.movie, .audio, .image]
    var seen = Set(ts.map { $0.identifier })
    for e in extensions {
      guard let t = UTType(filenameExtension: e) else { continue }
      if t.identifier.hasPrefix("dyn.") { continue }
      if seen.insert(t.identifier).inserted { ts.append(t) }
    }
    return ts
  }

  static func register(appURL: URL, completion: @escaping (Int, Int) -> Void) {
    let all = types()
    var index = 0
    var ok = 0
    func next() {
      guard index < all.count else {
        completion(ok, all.count)
        return
      }
      let t = all[index]
      index += 1
      var finished = false
      let timeout = DispatchWorkItem {
        guard !finished else { return }
        finished = true
        next()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
      NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: t) { error in
        guard !finished else { return }
        finished = true
        timeout.cancel()
        if error == nil { ok += 1 }
        DispatchQueue.main.async { next() }
      }
    }
    next()
  }
}

// mpv 结束播放回调（C 函数指针，不能捕获上下文）
let endFileCallback: @convention(c) (Int32) -> Void = { reason in
  DispatchQueue.main.async {
    (NSApp.delegate as? AppDelegate)?.player?.handleEndFile(reason)
  }
}

// mpv 通知我们“有新帧需要画”
let renderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
  guard let ctx else { return }
  let c = Unmanaged<Controller>.fromOpaque(ctx).takeUnretainedValue()
  c.requestRender()
}

func prop(_ h: UnsafeMutableRawPointer, _ name: String) -> String? {
  guard let p = sh_get_prop(h, name) else { return nil }
  defer { sh_free(p) }
  return String(cString: p)
}

func propDouble(_ h: UnsafeMutableRawPointer, _ name: String) -> Double {
  Double(prop(h, name) ?? "") ?? 0
}

func propBool(_ h: UnsafeMutableRawPointer, _ name: String) -> Bool {
  let v = prop(h, name)
  return v == "yes" || v == "true"
}

func fmtTime(_ seconds: Double) -> String {
  let s = (seconds.isNaN || seconds < 0) ? 0 : seconds
  let t = Int(s)
  if t >= 3600 { return String(format: "%d:%02d:%02d", t/3600, t/60%60, t%60) }
  return String(format: "%d:%02d", t/60, t%60)
}

// 视频显示视图：一个普通的 NSView，画面由自定义的 CAOpenGLLayer 绘制。
// 用 CAOpenGLLayer 而不是 NSOpenGLView，是因为只有图层能单独标记 HDR 色彩空间（PQ），
// 从而让杜比视界/HDR 在 XDR 屏幕上正确点亮，而不影响窗口里的控制条。
final class MPVGLView: NSView {
  weak var controller: Controller? {
    didSet { (layer as? MPVLayer)?.controller = controller }
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    wantsExtendedDynamicRangeOpenGLSurface = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func makeBackingLayer() -> CALayer {
    let l = MPVLayer()
    l.controller = controller
    return l
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
  }
  override func layout() {
    super.layout()
    updateScale()
  }
  func updateScale() {
    guard let l = layer as? MPVLayer else { return }
    let s = window?.backingScaleFactor ?? 2
    if l.contentsScale != s { l.contentsScale = s }
    l.setNeedsDisplay()
  }
}

final class MPVLayer: CAOpenGLLayer {
  weak var controller: Controller?
  private(set) var cglPixelFormat: CGLPixelFormatObj?
  private(set) var cglContext: CGLContextObj?

  override init() {
    super.init()
    isAsynchronous = false

    let attrs: [CGLPixelFormatAttribute] = [
      kCGLPFAAccelerated,
      kCGLPFADoubleBuffer,
      kCGLPFAColorSize, CGLPixelFormatAttribute(24),
      kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
      kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
      CGLPixelFormatAttribute(0),
    ]
    var pf: CGLPixelFormatObj?
    var npix: GLint = 0
    if CGLChoosePixelFormat(attrs, &pf, &npix) == kCGLNoError, let pf {
      cglPixelFormat = pf
      var ctx: CGLContextObj?
      if CGLCreateContext(pf, nil, &ctx) == kCGLNoError, let ctx {
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLEnable(ctx, kCGLCEMPEngine)
        cglContext = ctx
      }
    }
  }

  override init(layer: Any) {
    super.init(layer: layer)
    if let other = layer as? MPVLayer {
      cglPixelFormat = other.cglPixelFormat
      cglContext = other.cglContext
      controller = other.controller
      isAsynchronous = other.isAsynchronous
      contentsScale = other.contentsScale
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
    cglPixelFormat!
  }
  override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
    cglContext!
  }

  override func canDraw(inCGLContext ctx: CGLContextObj,
                        pixelFormat pf: CGLPixelFormatObj,
                        forLayerTime t: CFTimeInterval,
                        displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
    true
  }

  override func draw(inCGLContext ctx: CGLContextObj,
                     pixelFormat pf: CGLPixelFormatObj,
                     forLayerTime t: CFTimeInterval,
                     displayTime ts: UnsafePointer<CVTimeStamp>?) {
    CGLSetCurrentContext(ctx)
    controller?.drawVideo(in: self)
    glFlush()
  }
}

// 图片显示：ImageIO/Core Image 解码（支持分块 HEIC 与 HDR 增益图），
// 再用 Metal 画到 EDR 图层，保证 iPhone 的 HDR 照片能按 HDR 显示。
final class HDRImageView: NSView {
  private let metalLayer = CAMetalLayer()
  private let ciContext: CIContext
  private let commandQueue: MTLCommandQueue?
  private var image: CIImage?
  private var imageColorSpace: CGColorSpace?
  private var isHDR = false
  private var loaded = false
  private var zoom: CGFloat = 1
  private var pan = CGPoint.zero
  private var sourceTexture: MTLTexture?
  private var renderScheduled = false
  private var lastRenderTime: CFTimeInterval = 0
  // 动图（GIF / APNG / 动态 WebP）
  private var animSource: CGImageSource?
  private var animFrames = 0
  private var animIndex = 0
  private var animTimer: Timer?
  private var animationPaused = false

  init?(frame frameRect: NSRect, url: URL) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return nil }
    ciContext = CIContext(mtlDevice: device)
    commandQueue = queue
    super.init(frame: frameRect)
    metalLayer.device = device
    metalLayer.pixelFormat = .rgba16Float
    metalLayer.framebufferOnly = false
    metalLayer.contentsScale = 2
    wantsLayer = true
    load(url)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func makeBackingLayer() -> CALayer { metalLayer }

  override func layout() {
    super.layout()
    updateScale()
    clampPan()
    render()
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
    clampPan()
    render()
  }

  func refresh() {
    updateScale()
    clampPan()
    render()
  }

  // 触控板双指捏合缩放（以手势位置为中心）
  override func magnify(with event: NSEvent) {
    let anchor = convert(event.locationInWindow, from: nil)
    let oldZoom = zoom
    zoom = min(8, max(1, zoom * (1 + event.magnification)))
    guard abs(zoom - oldZoom) > 0.0001 else { return }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let ratio = zoom / oldZoom
    pan.x = anchor.x - center.x - ((anchor.x - center.x) - pan.x) * ratio
    pan.y = anchor.y - center.y - ((anchor.y - center.y) - pan.y) * ratio
    if zoom <= 1.001 { pan = .zero }
    clampPan()
    scheduleRender()
  }

  // 放大后可以双指滑动查看其它区域
  override func scrollWheel(with event: NSEvent) {
    guard zoom > 1.001 else { return }
    pan.x += event.scrollingDeltaX
    pan.y -= event.scrollingDeltaY   // 自然滚动：手指上推，画面跟着上移
    clampPan()
    scheduleRender()
  }

  private func clampPan() {
    guard let image, bounds.width > 0, bounds.height > 0 else { pan = .zero; return }
    let extent = image.extent
    let fit = min(bounds.width / extent.width, bounds.height / extent.height)
    let imgW = extent.width * fit * zoom
    let imgH = extent.height * fit * zoom
    let maxX = max(0, (imgW - bounds.width) / 2)
    let maxY = max(0, (imgH - bounds.height) / 2)
    pan.x = min(maxX, max(-maxX, pan.x))
    pan.y = min(maxY, max(-maxY, pan.y))
  }

  private func updateScale() {
    let s = window?.backingScaleFactor ?? 2
    if metalLayer.contentsScale != s { metalLayer.contentsScale = s }
  }

  private func load(_ url: URL) {
    // 多帧图片直接逐帧播放
    if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 1 {
      startAnimation(src)
      return
    }

    var ci: CIImage?
    if #available(macOS 14.0, *) {
      // 有 HDR 增益图时展开成 PQ 图像；普通图片会原样返回
      ci = CIImage(contentsOf: url, options: [.expandToHDR: true])
    }
    if ci == nil { ci = CIImage(contentsOf: url) }
    guard let input = ci else { return }

    image = input
    let sourceCS = input.colorSpace
    let name = sourceCS?.name as String? ?? ""
    isHDR = name.contains("PQ") || name.contains("HLG") || name.contains("2100")
    // HDR 内容转成扩展线性 P3 再交给图层：Core Animation 会按当前屏幕的
    // EDR headroom 做映射。直接把 PQ 码值画到 CAMetalLayer 时，部分 macOS
    // 版本会重复套用传递函数，导致整体过亮、高光直接爆掉。
    if isHDR {
      imageColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    } else {
      imageColorSpace = sourceCS ?? CGColorSpace(name: CGColorSpace.sRGB)
    }
    if let cs = imageColorSpace { metalLayer.colorspace = cs }
    metalLayer.wantsExtendedDynamicRangeContent = isHDR
    loaded = true
    // 大图先一次性渲染进 GPU 纹理；之后缩放/平移只采样纹理，
    // 不再每帧重新解码并按新尺寸缩小原图（48MP 图原来一帧要 400ms）
    if let cs = imageColorSpace {
      // PQ 是绝对亮度：参考白 203 nit 转到扩展线性空间后约为 2.54，
      // 直接显示会整体过亮、高光爆掉。按 80/203 归一化，让 SDR 白回到 1.0。
      let content = isHDR ? normalizeHDRWhite(input) : input
      cacheToTexture(content, colorSpace: cs)
      // 纹理缓存完成，清掉 Core Image 中间缓存，避免原图/中间结果常驻
      ciContext.clearCaches()
    }
    scheduleRender()
  }

  // 把 PQ 的证书白（203 nit）映射到扩展线性空间的 1.0（参考白 80 nit）
  private func normalizeHDRWhite(_ img: CIImage) -> CIImage {
    let k = CGFloat(80.0 / 203.0)
    return img.applyingFilter("CIColorMatrix", parameters: [
      "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
      "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
    ])
  }

  private func startAnimation(_ src: CGImageSource) {
    animSource = src
    animFrames = CGImageSourceGetCount(src)
    animIndex = 0
    animationPaused = false
    guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
    image = CIImage(cgImage: cg)
    imageColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    if let cs = imageColorSpace { metalLayer.colorspace = cs }
    isHDR = false
    metalLayer.wantsExtendedDynamicRangeContent = false
    loaded = true
    scheduleRender()
    scheduleNextFrame()
  }

  private func frameDelay(_ index: Int) -> Double {
    guard let src = animSource,
          let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [String: Any] else { return 0.1 }
    let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any]
    let raw = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? NSNumber)?.doubleValue
      ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? NSNumber)?.doubleValue
      ?? 0.1
    return raw < 0.011 ? 0.1 : min(raw, 10)
  }

  private func scheduleNextFrame() {
    animTimer?.invalidate()
    guard animFrames > 1, !animationPaused else { return }
    let t = Timer(timeInterval: frameDelay(animIndex), repeats: false) { [weak self] _ in
      guard let self, let src = self.animSource else { return }
      self.animIndex = (self.animIndex + 1) % self.animFrames
      if let cg = CGImageSourceCreateImageAtIndex(src, self.animIndex, nil) {
        self.image = CIImage(cgImage: cg)
        self.render()
      }
      self.scheduleNextFrame()
    }
    RunLoop.main.add(t, forMode: .common)
    animTimer = t
  }

  // 窗口被遮挡/最小化时暂停动图，省电
  func setAnimating(_ on: Bool) {
    guard animFrames > 1 else { return }
    if on {
      if animationPaused {
        animationPaused = false
        scheduleNextFrame()
      }
    } else {
      animationPaused = true
      animTimer?.invalidate()
      animTimer = nil
    }
  }

  deinit { animTimer?.invalidate() }

  private func cacheToTexture(_ ci: CIImage, colorSpace cs: CGColorSpace) {
    guard let device = metalLayer.device else { return }
    // 平移到位图原点，并限制最大纹理边长
    let origin = ci.extent.origin
    var img = ci.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    let ext = img.extent
    // 纹理上限 4096：48MP 照片若按 8192 缓存，RGBA16F 要占约 390MB；
    // 4096 已足够覆盖常见屏幕和 2 倍缩放，显存/内存降到约四分之一。
    let maxDim = 4096
    let down = min(1, CGFloat(maxDim) / max(ext.width, ext.height))
    let w = max(1, Int((ext.width * down).rounded()))
    let h = max(1, Int((ext.height * down).rounded()))
    if down < 1 {
      img = img.transformed(by: CGAffineTransform(scaleX: down, y: down))
    }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: isHDR ? .rgba16Float : .bgra8Unorm,
      width: w, height: h, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .private
    guard let tex = device.makeTexture(descriptor: desc),
          let cb = commandQueue?.makeCommandBuffer() else { return }
    ciContext.render(img, to: tex, commandBuffer: cb,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: cs)
    cb.commit()
    cb.waitUntilCompleted()
    if let cached = CIImage(mtlTexture: tex, options: [.colorSpace: cs]) {
      sourceTexture = tex
      image = cached
    }
  }

  // 每帧最多渲染一次；手势事件再密也不会堆积
  private func scheduleRender() {
    guard loaded, !renderScheduled else { return }
    renderScheduled = true
    let delay = max(0, 1.0 / 60.0 - (CACurrentMediaTime() - lastRenderTime))
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.renderScheduled = false
      self.render()
    }
  }

  private func render() {
    guard loaded, let image, let queue = commandQueue else { return }
    lastRenderTime = CACurrentMediaTime()
    let scale = metalLayer.contentsScale
    let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    guard let drawable = metalLayer.nextDrawable() else { return }

    let target = CGRect(origin: .zero, size: size)
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return }
    let fit = min(target.width / extent.width, target.height / extent.height)
    let s = fit * zoom
    let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    let dx = (target.width - scaled.extent.width) / 2 - scaled.extent.origin.x + pan.x * scale
    let dy = (target.height - scaled.extent.height) / 2 - scaled.extent.origin.y + pan.y * scale
    let positioned = scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))

    guard let cb = queue.makeCommandBuffer(), let cs = imageColorSpace else { return }
    ciContext.render(positioned, to: drawable.texture, commandBuffer: cb,
                     bounds: target, colorSpace: cs)
    cb.present(drawable)
    cb.commit()
  }
}

final class Controller: NSObject, NSWindowDelegate {
  private(set) var session: Session
  var rootView: NSView!
  var h: UnsafeMutableRawPointer!
  var window: NSWindow!
  var videoView: MPVGLView!
  var imageView: HDRImageView!
  var playBtn: NSButton!
  var slider: NSSlider!
  var timeLabel: NSTextField!
  var volSlider: NSSlider!
  var volImage: NSTextField!
  var fullBtn: NSButton!
  var subPopup: NSPopUpButton!
  var audioPopup: NSPopUpButton!
  var controlBar: NSView!
  var timer: DispatchSourceTimer?
  let mpvQ = DispatchQueue(label: "mpv.api")   // 所有 mpv 调用都在这里，避免和主线程死锁
  var dragging = false
  var duration: Double = 0
  var lastTracksJSON = ""
  var lastChaptersJSON = ""
  var hasStarted = false
  var renderReady = false
  var drawCount = 0
  // 图片没有时间轴，不显示底部控制条
  var barHeight: CGFloat { session.image == true ? 0 : 44 }
  var barVisible = false
  var hideWork: DispatchWorkItem?
  var mouseMonitor: Any?
  var lastWindowVisible = true
  var autoPaused = false
  var pollMs = 250
  var pausedNow = false
  var positionNow = 0.0
  // 每个文件记住上次的播放位置和音轨/字幕轨
  var currentAid = ""
  var currentSid = ""
  var lastPersistedPosition = -1.0
  var endStateSaved = false
  // 前台播放时持有的防休眠断言
  var sleepActivity: NSObjectProtocol?
  // 全屏时自动隐藏鼠标
  var cursorHideWork: DispatchWorkItem?
  var cursorHiddenUntilMove = false

  init(_ s: Session) {
    session = s
    super.init()
  }

  // ---------- 窗口 ----------
  func show() {
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    // 按视频宽高比开窗，并确保整个窗口（含标题栏和控制条）不超出屏幕
    var aspect: CGFloat = 16.0 / 9.0
    if let vw = session.width, let vh = session.height, vw > 0, vh > 0 {
      aspect = CGFloat(vw / vh)
    }
    let titleBar: CGFloat = 28
    let maxVideoH = max(240, screen.height - titleBar - 20)
    let maxVideoW = max(320, screen.width - 20)

    var videoH = maxVideoH
    var videoW = videoH * aspect
    if videoW > maxVideoW {
      videoW = maxVideoW
      videoH = videoW / aspect
    }
    if videoW > 1280 { videoW = 1280; videoH = videoW / aspect }

    let contentW = videoW
    let contentH = videoH

    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered, defer: false)
    window.title = session.title
    window.backgroundColor = .black
    window.minSize = NSSize(width: 480, height: 300)
    window.delegate = self
    window.collectionBehavior = [.fullScreenPrimary]
    window.appearance = NSAppearance(named: .darkAqua)
    window.acceptsMouseMovedEvents = true

    let root = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
    root.autoresizingMask = [.width, .height]
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.black.cgColor
    rootView = root

    // 图片走原生 ImageIO/Metal；视频走 libmpv
    if session.image == true {
      imageView = HDRImageView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH),
                               url: URL(fileURLWithPath: session.file))
      if let iv = imageView { root.addSubview(iv) }
    } else {
      videoView = MPVGLView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
      videoView.controller = self
      root.addSubview(videoView)
    }

    // 控制条覆盖在视频底部，显示/隐藏不会改变视频尺寸
    controlBar = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: barHeight))
    controlBar.wantsLayer = true
    controlBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.84).cgColor
    controlBar.isHidden = true
    root.addSubview(controlBar)

    playBtn = NSButton(title: "❚❚", target: self, action: #selector(togglePlay))
    playBtn.bezelStyle = .inline
    playBtn.isBordered = false
    playBtn.font = NSFont.systemFont(ofSize: 16)
    controlBar.addSubview(playBtn)

    slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(seekAction))
    slider.isContinuous = true
    controlBar.addSubview(slider)

    timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    timeLabel.textColor = .white
    timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    timeLabel.alignment = .right
    controlBar.addSubview(timeLabel)

    volImage = NSTextField(labelWithString: "🔊")
    volImage.font = NSFont.systemFont(ofSize: 12)
    controlBar.addSubview(volImage)

    volSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: self, action: #selector(volumeAction))
    controlBar.addSubview(volSlider)

    fullBtn = NSButton(title: "⤢", target: self, action: #selector(fullscreen))
    fullBtn.bezelStyle = .inline
    fullBtn.isBordered = false
    fullBtn.font = NSFont.systemFont(ofSize: 16)
    controlBar.addSubview(fullBtn)

    window.contentView = root
    window.center()
    layoutViews()

    buildMenu()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    setupAutoHide()
    // 窗口被完全遮挡/最小化时暂停解码和动图，避免后台空耗
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(windowVisibilityChanged),
                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
    nc.addObserver(self, selector: #selector(windowVisibilityChanged),
                   name: NSWindow.didMiniaturizeNotification, object: window)
    nc.addObserver(self, selector: #selector(windowVisibilityChanged),
                   name: NSWindow.didDeminiaturizeNotification, object: window)
    nc.addObserver(self, selector: #selector(appActiveChanged),
                   name: NSApplication.didBecomeActiveNotification, object: nil)
    nc.addObserver(self, selector: #selector(appActiveChanged),
                   name: NSApplication.didResignActiveNotification, object: nil)

    if session.image == true {
      imageView?.refresh()
    } else {
      startMpv()          // 先初始化 mpv，渲染上下文才能挂到它上面
      configureEDR()
      // render context 必须先于 loadfile 存在，否则 mpv 会直接放弃视频输出
      if let l = videoView.layer as? MPVLayer, let c = l.cglContext {
        CGLSetCurrentContext(c)
        createRenderContext()
      }
      loadFile()
    }

    if ProcessInfo.processInfo.environment["PLAYER_SELFTEST"] == "1" { runSelfTest() }
  }

  // 自测：缩放、复原、全屏、退出全屏，检查渲染是否持续、窗口是否回弹
  func runSelfTest() {
    let check = { [weak self] (tag: String) in
      guard let self else { return }
      NSLog("SELFTEST \(tag): frame=\(self.window.frame) draws=\(self.drawCount) visible=\(self.window.isVisible)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      check("before")
      self.window.performZoom(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check("zoom1") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        self.window.performZoom(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { check("restored") }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        self.window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { check("fullscreen") }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
        self.window.toggleFullScreen(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { check("windowed") }
      }
    }
  }

  // ---------- 在同一窗口里换文件 ----------
  // 播放器进程只持有一个 mpv 上下文（mpvshim 是单例），因此新打开的文件
  // 复用当前窗口：同类视频直接 loadfile，图片换 ImageIO 视图，视频/图片互切时隐藏另一侧。
  func switchTo(_ s: Session) {
    guard s.file != session.file else {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    savePlaybackState(flush: true)
    session = s
    window.title = s.title
    duration = 0
    lastTracksJSON = ""
    lastChaptersJSON = ""
    autoPaused = false
    pausedNow = false
    positionNow = 0
    currentAid = ""
    currentSid = ""
    lastPersistedPosition = -1
    endStateSaved = false
    barVisible = false
    hideWork?.cancel()
    updateSleepAssertion()
    controlBar.isHidden = true
    slider.maxValue = 1
    slider.doubleValue = 0
    timeLabel.stringValue = "0:00 / 0:00"
    playBtn.title = "❚❚"
    rebuildActionMenus()

    if s.image == true {
      // 视频转图片：暂停并停止解码，留下 mpv 上下文供之后再切回视频
      if h != nil {
        mpv { h in
          sh_set_prop(h, "pause", "yes")
          sh_command(h, "stop")
        }
      }
      videoView?.isHidden = true
      imageView?.removeFromSuperview()
      imageView = HDRImageView(frame: rootView.bounds,
                               url: URL(fileURLWithPath: s.file))
      rootView.addSubview(imageView, positioned: .below, relativeTo: controlBar)
      imageView.refresh()
    } else {
      imageView?.removeFromSuperview()
      imageView = nil
      if videoView == nil {
        videoView = MPVGLView(frame: rootView.bounds)
        videoView.controller = self
        rootView.addSubview(videoView, positioned: .below, relativeTo: controlBar)
        startMpv()
        configureEDR()
        if let l = videoView.layer as? MPVLayer, let c = l.cglContext {
          CGLSetCurrentContext(c)
          createRenderContext()
        }
      } else {
        videoView.isHidden = false
        configureEDR()
        applyHdrOptions()
      }
      loadFile()
    }

    resizeWindowFor(s)
    layoutViews()
    imageView?.refresh()
    (videoView?.layer as? MPVLayer)?.setNeedsDisplay()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if s.image != true { pointerMoved() }
  }

  // 换文件时按新内容的宽高比调整窗口，保持窗口中心不跳到别的屏幕
  func resizeWindowFor(_ s: Session) {
    guard let window, !window.styleMask.contains(.fullScreen) else { return }
    var aspect: CGFloat = 16.0 / 9.0
    if let vw = s.width, let vh = s.height, vw > 0, vh > 0 {
      aspect = CGFloat(vw / vh)
    }
    let screen = window.screen?.visibleFrame
      ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let titleBar: CGFloat = 28
    let maxVideoH = max(240, screen.height - titleBar - 20)
    let maxVideoW = max(320, screen.width - 20)
    var videoH = maxVideoH
    var videoW = videoH * aspect
    if videoW > maxVideoW {
      videoW = maxVideoW
      videoH = videoW / aspect
    }
    if videoW > 1280 { videoW = 1280; videoH = videoW / aspect }
    let size = NSSize(width: videoW, height: videoH)
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
    frame.origin = NSPoint(x: center.x - frame.width / 2,
                           y: center.y - frame.height / 2)
    frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
    window.setFrame(frame, display: true, animate: false)
  }

  // 切换视频后重新设置 HDR 输出参数；SDR 文件要收回上一次的 PQ 设置
  func applyHdrOptions() {
    guard h != nil else { return }
    let hdr = session.hdr == true
    let prim = mpvTargetPrimaries()
    mpvQ.async { [weak self] in
      guard let self, let h = self.h else { return }
      sh_set_prop(h, "sub-delay", "0")
      sh_set_prop(h, "pause", "no")
      if hdr {
        sh_set_prop(h, "icc-profile-auto", "no")
        sh_set_prop(h, "target-prim", prim)
        sh_set_prop(h, "target-trc", "pq")
        sh_set_prop(h, "target-peak", "1000")
        sh_set_prop(h, "tone-mapping", "auto")
      } else {
        sh_set_prop(h, "target-prim", "auto")
        sh_set_prop(h, "target-trc", "auto")
        sh_set_prop(h, "target-peak", "auto")
        sh_set_prop(h, "tone-mapping", "auto")
      }
    }
  }

  // HDR：把视频图层标记成 PQ 色彩空间并开启 EDR，
  // mpv 端配合 target-trc=pq 直接输出 PQ 码值，由 macOS 合成器映射到 XDR 屏幕。
  func configureEDR() {
    guard let layer = videoView.layer as? MPVLayer else { return }
    if session.hdr == true {
      let prim = (session.primaries ?? "").lowercased()
      let name = prim.contains("p3") ? CGColorSpace.displayP3_PQ : CGColorSpace.itur_2100_PQ
      if let cs = CGColorSpace(name: name) {
        layer.colorspace = cs
        layer.wantsExtendedDynamicRangeContent = true
        return
      }
    }
    // SDR：按屏幕色彩空间做色彩匹配
    layer.wantsExtendedDynamicRangeContent = false
    if let cs = window.screen?.colorSpace?.cgColorSpace { layer.colorspace = cs }
  }

  func mpvTargetPrimaries() -> String {
    let p = (session.primaries ?? "").lowercased()
    if p.contains("p3") { return "display-p3" }
    return "bt.2020"
  }

  // 手动布局，窗口缩放时也保持一致
  func layoutViews() {
    guard let content = window?.contentView else { return }
    let b = content.bounds
    controlBar.frame = NSRect(x: 0, y: 0, width: b.width, height: barHeight)
    // 视频始终铺满内容区，控制条覆盖在底部
    if let iv = imageView {
      iv.frame = b
    } else if let vv = videoView {
      vv.frame = b
    }

    playBtn.frame = NSRect(x: 10, y: 8, width: 30, height: 28)
    slider.frame = NSRect(x: 48, y: 12, width: max(80, b.width - 340), height: 20)
    timeLabel.frame = NSRect(x: b.width - 285, y: 14, width: 100, height: 16)
    volImage.frame = NSRect(x: b.width - 175, y: 14, width: 20, height: 16)
    volSlider.frame = NSRect(x: b.width - 155, y: 12, width: 85, height: 20)
    fullBtn.frame = NSRect(x: b.width - 55, y: 8, width: 30, height: 28)
  }

  // ---------- 控制条自动显隐 ----------
  // 只有鼠标移到底部控制条区域才显示；离开后 3 秒隐藏。
  // 控制条覆盖在视频上，显隐不会改变视频尺寸。
  func setupAutoHide() {
    guard mouseMonitor == nil else { return }
    mouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown]
    ) { [weak self] event in
      guard let self, event.window === self.window else { return event }
      self.mouseActivity()
      self.pointerMoved()
      return event
    }
    // 打开时如果鼠标正好在底部区域，直接显示
    pointerMoved()
  }

  // 鼠标是否在底部控制条区域（含上方一点余量，便于移入触发）
  private func pointerInBarZone() -> Bool {
    guard let window, window.isVisible else { return false }
    let screenPoint = NSEvent.mouseLocation
    guard window.frame.contains(screenPoint) else { return false }
    let inWindow = window.convertPoint(fromScreen: screenPoint)
    let p = controlBar.convert(inWindow, from: nil)
    return controlBar.bounds.insetBy(dx: 0, dy: -10).contains(p)
  }

  private func pointerMoved() {
    // 只有进入底部区域才显示/重新计时。离开后沿用最后一次计时，
    // 鼠标在画面其它地方怎么动都不会推迟隐藏。
    guard pointerInBarZone() else { return }
    if !barVisible { setBarVisible(true) }
    scheduleBarHide()
  }

  private func scheduleBarHide() {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.pointerInBarZone() {
        // 鼠标还在控制条区域：过一会儿再检查（离开窗口不会触发事件）
        self.scheduleBarHide()
        return
      }
      self.setBarVisible(false)
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func setBarVisible(_ visible: Bool) {
    guard barHeight > 0, visible != barVisible else { return }
    barVisible = visible
    controlBar.isHidden = !visible
    (videoView?.layer as? MPVLayer)?.setNeedsDisplay()
  }

  // ---------- 全屏鼠标自动隐藏 ----------
  // 鼠标停止移动 1.5 秒后隐藏；控制条还显示时不隐藏，避免看着控件却找不到鼠标。
  private func mouseActivity() {
    cursorHiddenUntilMove = false
    scheduleCursorHide()
  }

  private func scheduleCursorHide() {
    cursorHideWork?.cancel()
    guard let w = window, w.styleMask.contains(.fullScreen), NSApp.isActive else {
      showCursorNow()
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self, let w = self.window,
            w.styleMask.contains(.fullScreen), NSApp.isActive else { return }
      if self.barVisible {
        self.scheduleCursorHide()
        return
      }
      NSCursor.setHiddenUntilMouseMoves(true)
      self.cursorHiddenUntilMove = true
    }
    cursorHideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func showCursorNow() {
    cursorHideWork?.cancel()
    cursorHideWork = nil
    if cursorHiddenUntilMove {
      NSCursor.setHiddenUntilMouseMoves(false)
      cursorHiddenUntilMove = false
    }
  }

  // ---------- 后台省电 ----------
  @objc func windowVisibilityChanged(_ note: Notification) {
    guard let window else { return }
    let visible = window.isVisible && !window.isMiniaturized
      && window.occlusionState.contains(.visible)
    guard visible != lastWindowVisible else { return }
    lastWindowVisible = visible
    if session.image == true {
      imageView?.setAnimating(visible)
    } else {
      setPlaybackSuspended(!visible)
    }
    updateSleepAssertion()
  }

  @objc func appActiveChanged(_ note: Notification) {
    if note.name == NSApplication.didResignActiveNotification {
      updateSleepAssertion()
      showCursorNow()
    } else {
      updateSleepAssertion()
      if window?.styleMask.contains(.fullScreen) == true { scheduleCursorHide() }
    }
  }

  // 只有“播放器在前台 + 窗口可见 + 正在播放”才阻止系统/显示器休眠。
  // 暂停、播放结束、窗口被遮挡、切到别的应用都会释放断言。
  func updateSleepAssertion() {
    guard window != nil else { return }
    let foreground = NSApp.isActive && window.isVisible
      && !window.isMiniaturized && window.occlusionState.contains(.visible)
    let atEnd = duration > 0 && positionNow >= duration - 0.05
    let wanted = foreground && session.image != true && hasStarted && !pausedNow && !atEnd
    if wanted {
      if sleepActivity == nil {
        sleepActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
          reason: "正在播放媒体")
      }
    } else {
      endSleepActivity()
    }
  }

  private func endSleepActivity() {
    if let a = sleepActivity {
      ProcessInfo.processInfo.endActivity(a)
      sleepActivity = nil
    }
  }

  // 自己触发的暂停才自动恢复，用户手动暂停的状态保持不变
  private func setPlaybackSuspended(_ suspended: Bool) {
    guard h != nil else { return }
    mpvQ.async { [weak self] in
      guard let self, let h = self.h else { return }
      if suspended {
        if !propBool(h, "pause") {
          self.autoPaused = true
          sh_set_prop(h, "pause", "yes")
        }
      } else if self.autoPaused {
        self.autoPaused = false
        sh_set_prop(h, "pause", "no")
      }
    }
  }

  func windowDidResize(_ notification: Notification) {
    layoutViews()
    if let iv = imageView { iv.refresh() }
    else { (videoView?.layer as? MPVLayer)?.setNeedsDisplay() }
  }
  func windowDidEnterFullScreen(_ notification: Notification) {
    layoutViews()
    imageView?.refresh()
    scheduleCursorHide()
    updateSleepAssertion()
  }
  func windowDidExitFullScreen(_ notification: Notification) {
    layoutViews()
    imageView?.refresh()
    showCursorNow()
    updateSleepAssertion()
  }

  // ---------- mpv ----------
  func startMpv() {
    setupMpv()
  }

  func setupMpv() {
    h = sh_create()
    guard h != nil else {
      DispatchQueue.main.async { NSAlert.show("无法启动 mpv") }
      return
    }

    var opts: [(String, String)] = [
      ("vo", "libmpv"),                 // 自己不画，交给 render API
      ("hwdec", "videotoolbox"),        // 硬解，零拷贝到 GL
      ("osc", "no"),
      ("input-default-bindings", "no"),
      ("input-vo-keyboard", "no"),
      ("terminal", "no"),
      ("config", "no"),
      ("msg-level", "all=error"),
      ("osd-on-seek", "no"),            // 不显示 mpv 自带的 seek 进度条，只用下面的控制条
      ("keep-open", "yes"),
      ("keep-open-pause", "yes"),
      ("auto-window-resize", "no"),
      ("sub-auto", "no"),
      ("audio-file-auto", "no"),
      ("slang", "chi,zho,zh,zh-Hans,zh-CN,zh-Hant,en,eng"),
      ("alang", "chi,zho,zh,en,eng"),
      ("save-position-on-quit", "no"),
      ("input-ipc-server", ipcPath()),
    ]
    if session.hdr == true {
      // 输出 PQ 码值，交给 EDR 图层呈现（与 IINA 相同的做法）
      opts += [
        ("icc-profile-auto", "no"),
        ("target-prim", mpvTargetPrimaries()),
        ("target-trc", "pq"),
        ("target-peak", "1000"),
        ("tone-mapping", "auto"),
      ]
    }
    for (k, v) in opts {
      let r = sh_set_option(h, k, v)
      if r < 0 { NSLog("mpv option %@ error: %@", k, String(cString: sh_error(r))) }
    }
    let ir = sh_initialize(h)
    if ir < 0 {
      let msg = "mpv 初始化失败：" + String(cString: sh_error(ir))
      DispatchQueue.main.async { NSAlert.show(msg) }
      return
    }

    sh_set_endfile_cb(endFileCallback)
    hasStarted = true
  }

  // render context 就绪后再加载文件；所有 mpv 命令都排到同一个队列，
  // 保证切换 HDR 参数后才 loadfile
  func loadFile() {
    guard hasStarted else { return }
    let file = session.file
    let subs = session.subtitles ?? []
    let saved = savedPlaybackState(for: file)
    let start = (saved.time.isFinite && saved.time > 1) ? saved.time : 0
    // loadfile 的第 3 个参数是插入位置，第 4 个才是 per-file 选项；
    // 要写成：loadfile "file" replace 0 start=<秒>,aid=<id>,sid=<id>
    // 轨道选择必须作为 per-file 选项一起加载，不能在 loadfile 之后立刻 set：
    // 那时旧文件还在播，set aid/sid 会落到旧文件上，新文件仍是默认轨。
    var opts: [String] = []
    if start > 1 { opts.append("start=\(start)") }
    if let aid = saved.aid, !aid.isEmpty, aid != "auto" { opts.append("aid=\(aid)") }
    if let sid = saved.sid, !sid.isEmpty, sid != "auto" { opts.append("sid=\(sid)") }
    let optArg = opts.isEmpty ? "" : " 0 " + opts.joined(separator: ",")
    currentAid = saved.aid ?? ""
    currentSid = saved.sid ?? ""
    lastPersistedPosition = start
    endStateSaved = false
    mpvQ.async { [weak self] in
      guard let self, let h = self.h else { return }
      sh_command(h, "loadfile \(self.quote(file)) replace\(optArg)")
      for (i, sub) in subs.enumerated() {
        sh_command(h, "sub-add \(self.quote(sub)) \(i == 0 ? "select" : "auto")")
      }
    }
  }

  // ---------- 播放记忆 ----------
  private func stateKey(_ prefix: String, _ file: String) -> String { "\(prefix):\(file)" }

  private func savedPlaybackState(for file: String) -> (time: Double, aid: String?, sid: String?) {
    let d = UserDefaults.standard
    return (d.double(forKey: stateKey("resumeTime", file)),
            d.string(forKey: stateKey("aid", file)),
            d.string(forKey: stateKey("sid", file)))
  }

  // 记下当前时间与轨道；windowWillClose / 退出时 flush，播放中每 10 秒落一次盘
  func savePlaybackState(flush: Bool = false) {
    guard hasStarted, session.image != true, !session.file.isEmpty else { return }
    let atEnd = duration > 0 && positionNow >= duration - 5
    let time = atEnd ? 0 : max(0, positionNow)
    let d = UserDefaults.standard
    let file = session.file
    d.set(time, forKey: stateKey("resumeTime", file))
    if !currentAid.isEmpty { d.set(currentAid, forKey: stateKey("aid", file)) }
    if !currentSid.isEmpty { d.set(currentSid, forKey: stateKey("sid", file)) }
    if flush { d.synchronize() }
    lastPersistedPosition = time
  }

  // 由画布图层调用（此时 GL 上下文已 current）
  func drawVideo(in layer: MPVLayer) {
    guard h != nil else { return }
    if !renderReady { createRenderContext() }
    guard renderReady else { return }
    let scale = layer.contentsScale
    let w = Int32(max(1, (layer.bounds.width * scale).rounded()))
    let hh = Int32(max(1, (layer.bounds.height * scale).rounded()))
    var fbo: GLint = 0
    glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
    _ = sh_render_update()
    if sh_render_draw(Int32(fbo), w, hh, 1) >= 0 {
      drawCount += 1
      sh_render_report_swap()
    }
  }

  func createRenderContext() {
    guard h != nil, !renderReady else { return }
    var err = [CChar](repeating: 0, count: 256)
    let ctx = Unmanaged.passUnretained(self).toOpaque()
    let r = sh_render_create(h, renderUpdateCallback, ctx, &err, 256)
    if r < 0 {
      NSLog("render context 创建失败: %@", String(cString: err))
      DispatchQueue.main.async {
        NSAlert.show("无法初始化视频渲染：" + String(cString: err))
      }
      return
    }
    renderReady = true
    (videoView?.layer as? MPVLayer)?.setNeedsDisplay()
  }

  // mpv 的 update 回调可能在任意线程，切回主线程重绘
  func requestRender() {
    DispatchQueue.main.async { [weak self] in
      (self?.videoView.layer as? MPVLayer)?.setNeedsDisplay()
    }
  }

  func quote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }

  func ipcPath() -> String { "/tmp/ffmpeg-gui-player-\(getpid()).sock" }

  func handleEndFile(_ reason: Int32) {
    if reason == 0 {
      DispatchQueue.main.async {
        self.playBtn?.title = "▶"
        // 看到结尾后下次从头播，不要一打开就停在片尾
        self.positionNow = self.duration
        self.endStateSaved = true
        self.savePlaybackState(flush: true)
      }
    }
  }

  // ---------- 定时刷新（在后台队列读属性，主线程只更新界面）----------
  func startTimer() {
    timer?.cancel()
    let t = DispatchSource.makeTimerSource(queue: mpvQ)
    t.schedule(deadline: .now(), repeating: .milliseconds(250))
    t.setEventHandler { [weak self] in
      guard let self, let h = self.h else { return }
      let pos = propDouble(h, "time-pos")
      let dur = propDouble(h, "duration")
      let paused = propBool(h, "pause")
      // 暂停时（包括窗口被遮挡自动暂停）放慢界面刷新，减少唤醒
      let want = paused ? 1000 : 250
      if want != self.pollMs {
        self.pollMs = want
        self.timer?.schedule(deadline: .now() + .milliseconds(want),
                             repeating: .milliseconds(want))
      }
      let vol = propDouble(h, "volume")
      let tracks = prop(h, "track-list") ?? ""
      let chapters = prop(h, "chapter-list") ?? ""
      let aid = prop(h, "aid") ?? ""
      let sid = prop(h, "sid") ?? ""
      let eof = propBool(h, "eof-reached")
      DispatchQueue.main.async {
        self.applyUI(pos: pos, duration: dur, paused: paused, volume: vol,
                     tracks: tracks, chapters: chapters, aid: aid, sid: sid, eof: eof)
      }
    }
    t.resume()
    timer = t
  }

  // 主线程：只碰界面，不碰 mpv
  func applyUI(pos: Double, duration: Double, paused: Bool, volume: Double,
               tracks: String, chapters: String, aid: String, sid: String, eof: Bool) {
    self.duration = duration
    self.positionNow = pos
    self.pausedNow = paused
    if !aid.isEmpty { currentAid = aid }
    if !sid.isEmpty { currentSid = sid }
    // keep-open 卡在片尾时不一定发 end-file，这里补一次：下次从头播
    if eof {
      if !endStateSaved {
        endStateSaved = true
        positionNow = duration
        savePlaybackState(flush: true)
      }
    } else {
      endStateSaved = false
    }
    playBtn.title = paused ? "▶" : "❚❚"
    if !dragging {
      slider.maxValue = max(1, duration)
      slider.doubleValue = pos
      timeLabel.stringValue = "\(fmtTime(pos)) / \(fmtTime(duration))"
    }
    if !volSlider.isHighlighted { volSlider.doubleValue = volume }
    if tracks != lastTracksJSON { lastTracksJSON = tracks; rebuildTrackMenus(tracks) }
    if chapters != lastChaptersJSON { lastChaptersJSON = chapters; rebuildChapterMenu(chapters); rebuildMenuBar() }
    // 播放中每 10 秒记一次，意外退出也不会丢太多进度；结尾附近不记，避免下次一打开就结束
    if hasStarted, session.image != true, duration > 0, pos > 0, pos < duration - 5,
       abs(pos - lastPersistedPosition) >= 10 {
      savePlaybackState()
    }
    updateSleepAssertion()
  }

  // 在后台队列执行 mpv 调用；读到的值在主线程使用
  func mpv(_ block: @escaping (UnsafeMutableRawPointer) -> Void) {
    mpvQ.async { [weak self] in
      guard let self, let h = self.h else { return }
      block(h)
    }
  }

  // ---------- 控制 ----------
  @objc func togglePlay() {
    mpv { h in
      let paused = propBool(h, "pause")
      sh_set_prop(h, "pause", paused ? "no" : "yes")
    }
  }
  @objc func seekAction() {
    dragging = slider.currentEditor() != nil || NSEvent.pressedMouseButtons != 0
    guard !dragging else { return }
    let v = slider.doubleValue
    mpv { h in sh_command(h, "seek \(v) absolute exact") }
  }
  @objc func volumeAction() {
    let v = volSlider.doubleValue
    mpv { h in sh_set_prop(h, "volume", String(v)) }
  }
  @objc func fullscreen() { window.toggleFullScreen(nil) }
  @objc func openDocument() {
    (NSApp.delegate as? AppDelegate)?.chooseFile()
  }
  @objc func setAsDefault() {
    // 主程序内嵌的播放器不能把自己注册成默认（路径藏在 多媒体工具.app 里）
    var target = Bundle.main.bundleURL
    if target.path.contains(".app/Contents/Resources/") {
      let standalone = URL(fileURLWithPath: "/Applications/多媒体工具播放器.app")
      if FileManager.default.fileExists(atPath: standalone.path) {
        target = standalone
      } else {
        NSAlert.show("请先安装独立播放器，再设为默认打开方式。")
        return
      }
    }
    DefaultHandlers.register(appURL: target) { ok, total in
      NSAlert.show("已设为默认播放器：\(ok)/\(total) 种媒体类型。")
    }
  }
  @objc func back10() { seek(by: -10) }
  @objc func fwd10() { seek(by: 10) }
  @objc func seek(by d: Double) {
    mpv { h in
      let pos = propDouble(h, "time-pos")
      sh_command(h, "seek \(max(0, pos + d)) absolute exact")
    }
  }
  @objc func subCycle() { mpv { h in sh_command(h, "cycle sub") } }
  @objc func audioCycle() { mpv { h in sh_command(h, "cycle audio") } }
  @objc func disableSubtitles() {
    currentSid = "no"
    savePlaybackState(flush: true)
    mpv { h in sh_set_prop(h, "sid", "no") }
    flash("字幕已关闭")
  }
  @objc func subScaleUp() { stepSubSize(4) }
  @objc func subScaleDown() { stepSubSize(-4) }
  func stepSubSize(_ delta: Double) {
    mpv { h in
      let v = max(10, propDouble(h, "sub-font-size") + delta)
      sh_set_prop(h, "sub-font-size", String(v))
      DispatchQueue.main.async { self.flash("字幕字号 \(Int(v))") }
    }
  }
  @objc func subEarlier() { adjustSubDelay(-0.1) }
  @objc func subLater() { adjustSubDelay(0.1) }
  func adjustSubDelay(_ d: Double) {
    mpv { h in
      let v = propDouble(h, "sub-delay") + d
      sh_set_prop(h, "sub-delay", String(v))
      DispatchQueue.main.async { self.flash(String(format: "字幕偏移 %+.1f 秒", v)) }
    }
  }
  @objc func jumpChapter(_ item: NSMenuItem) {
    let t = item.representedObject as? Double ?? 0
    mpv { h in sh_command(h, "seek \(t) absolute exact") }
  }
  @objc func pickSub(_ item: NSMenuItem) {
    let id = item.representedObject as? String ?? "auto"
    currentSid = id
    savePlaybackState(flush: true)
    mpv { h in sh_set_prop(h, "sid", id) }
  }
  @objc func pickAudio(_ item: NSMenuItem) {
    let id = item.representedObject as? String ?? "auto"
    currentAid = id
    savePlaybackState(flush: true)
    mpv { h in sh_set_prop(h, "aid", id) }
  }
  @objc func pickPopupSub(_ sender: NSPopUpButton) {
    let id = sender.selectedItem?.representedObject as? String ?? "auto"
    currentSid = id
    savePlaybackState(flush: true)
    mpv { h in sh_set_prop(h, "sid", id) }
  }
  @objc func pickPopupAudio(_ sender: NSPopUpButton) {
    let id = sender.selectedItem?.representedObject as? String ?? "auto"
    currentAid = id
    savePlaybackState(flush: true)
    mpv { h in sh_set_prop(h, "aid", id) }
  }
  func flash(_ text: String) {
    window.title = "\(session.title)  ·  \(text)"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      if let self, self.window.title.hasPrefix(self.session.title) { self.window.title = self.session.title }
    }
  }

  // ---------- 菜单 ----------
  var subMenu = NSMenu(title: "字幕")
  var audioMenu = NSMenu(title: "音轨")
  var chapterMenu = NSMenu(title: "章节")
  var playMenu = NSMenu(title: "播放")

  func buildMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem(); main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "关闭播放器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let pItem = NSMenuItem(); main.addItem(pItem); pItem.submenu = playMenu
    add(playMenu, "播放 / 暂停", #selector(togglePlay), " ", [])
    add(playMenu, "后退 10 秒", #selector(back10), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [])
    add(playMenu, "前进 10 秒", #selector(fwd10), String(UnicodeScalar(NSRightArrowFunctionKey)!), [])
    add(playMenu, "全屏", #selector(fullscreen), "f", [.command, .control])
    playMenu.addItem(.separator())
    let audioHolder = NSMenuItem(title: "音轨", action: nil, keyEquivalent: "")
    audioHolder.submenu = audioMenu
    playMenu.addItem(audioHolder)
    let subHolder = NSMenuItem(title: "字幕", action: nil, keyEquivalent: "")
    subHolder.submenu = subMenu
    playMenu.addItem(subHolder)

    let fItem = NSMenuItem(); main.addItem(fItem)
    let fileMenu = NSMenu(title: "文件")
    let openItem = NSMenuItem(title: "打开…", action: #selector(openDocument), keyEquivalent: "o")
    openItem.target = self
    fileMenu.addItem(openItem)
    fileMenu.addItem(.separator())
    let defItem = NSMenuItem(title: "设为默认媒体播放器…", action: #selector(setAsDefault), keyEquivalent: "")
    defItem.target = self
    fileMenu.addItem(defItem)
    fItem.submenu = fileMenu

    let cItem = NSMenuItem(); main.addItem(cItem); cItem.submenu = chapterMenu

    let wItem = NSMenuItem(); main.addItem(wItem)
    let wm = NSMenu(title: "窗口")
    wm.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    wItem.submenu = wm

    if audioPopup == nil {
      audioPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 1, height: 1), pullsDown: false)
      subPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 1, height: 1), pullsDown: false)
      audioPopup.target = self; audioPopup.action = #selector(pickPopupAudio(_:))
      subPopup.target = self; subPopup.action = #selector(pickPopupSub(_:))
    }

    NSApp.mainMenu = main
    rebuildActionMenus()
  }

  func rebuildMenuBar() { rebuildActionMenus() }

  func rebuildActionMenus() {
    subMenu.removeAllItems()
    add(subMenu, "关闭字幕", #selector(disableSubtitles), "", [])
    subMenu.addItem(.separator())
    add(subMenu, "字号变大", #selector(subScaleUp), "=", [.command])
    add(subMenu, "字号变小", #selector(subScaleDown), "-", [.command])
    add(subMenu, "字幕提前 0.1 秒", #selector(subEarlier), "[", [.command])
    add(subMenu, "字幕延后 0.1 秒", #selector(subLater), "]", [.command])
    subMenu.title = "字幕"

    audioMenu.removeAllItems()
    audioMenu.title = "音轨"
    chapterMenu.removeAllItems()
    chapterMenu.title = "章节"
    playMenu.title = "播放"
    rebuildTrackMenus(lastTracksJSON)
    rebuildChapterMenu(lastChaptersJSON)
  }

  func rebuildTrackMenus(_ json: String) {
    guard let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
    subMenu.removeAllItems()
    add(subMenu, "关闭字幕", #selector(disableSubtitles), "", [])
    subMenu.addItem(.separator())
    add(subMenu, "字号变大", #selector(subScaleUp), "=", [.command])
    add(subMenu, "字号变小", #selector(subScaleDown), "-", [.command])
    add(subMenu, "字幕提前 0.1 秒", #selector(subEarlier), "[", [.command])
    add(subMenu, "字幕延后 0.1 秒", #selector(subLater), "]", [.command])
    subMenu.addItem(.separator())

    let subPop = NSMenu()
    subPop.addItem(withTitle: "关闭字幕", action: nil, keyEquivalent: "")
    audioMenu.removeAllItems()
    let audPop = NSMenu()
    audPop.addItem(withTitle: "默认", action: nil, keyEquivalent: "")
    var subCount = 0
    var audioCount = 0

    for t in arr {
      let type = t["type"] as? String ?? ""
      let id = t["id"] as? Int ?? 0
      let title = t["title"] as? String
      let lang = t["lang"] as? String
      let codec = t["codec"] as? String
      let selected = t["selected"] as? Bool ?? false
      var label = title?.isEmpty == false ? title! : (lang ?? "")
      if label.isEmpty { label = "\(codec ?? "") #\(id)" }
      if let lang, !lang.isEmpty, label != lang { label += " (\(lang))" }
      let item = NSMenuItem(title: label, action: #selector(pickSub(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = String(id)
      item.state = selected ? .on : .off
      if type == "sub" {
        subMenu.addItem(item)
        subCount += 1
        let p = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        p.representedObject = String(id)
        subPop.addItem(p)
      } else if type == "audio" {
        let ch = t["demux-channel-count"] as? Int ?? 0
        if ch > 0 { label += " · \(ch) 声道" }
        let a = NSMenuItem(title: label, action: #selector(pickAudio(_:)), keyEquivalent: "")
        a.target = self
        a.representedObject = String(id)
        a.state = selected ? .on : .off
        audioMenu.addItem(a)
        audioCount += 1
        let p = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        p.representedObject = String(id)
        audPop.addItem(p)
      }
    }
    if subCount == 0 {
      let none = NSMenuItem(title: "（无字幕轨）", action: nil, keyEquivalent: "")
      none.isEnabled = false
      subMenu.addItem(none)
    }
    if audioCount == 0 {
      let none = NSMenuItem(title: "（无音轨）", action: nil, keyEquivalent: "")
      none.isEnabled = false
      audioMenu.addItem(none)
    }
    if !subPopup.isHidden {
      subPopup.menu = subPop
      if !subPopup.menu!.items.isEmpty { subPopup.selectItem(at: 0) }
    }
    if !audioPopup.isHidden {
      audioPopup.menu = audPop
      if !audPop.items.isEmpty { audioPopup.selectItem(at: 0) }
    }
  }

  func rebuildChapterMenu(_ json: String) {
    chapterMenu.removeAllItems()
    guard let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !arr.isEmpty else {
      let none = NSMenuItem(title: "（无章节）", action: nil, keyEquivalent: "")
      none.isEnabled = false
      chapterMenu.addItem(none)
      return
    }
    for c in arr {
      let title = c["title"] as? String ?? ""
      let time = c["time"] as? Double ?? 0
      let item = NSMenuItem(title: "\(fmtTime(time))  \(title)", action: #selector(jumpChapter(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = time
      chapterMenu.addItem(item)
    }
  }

  func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) {
    let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
    mi.keyEquivalentModifierMask = mods
    mi.target = self
    m.addItem(mi)
  }

  func windowWillClose(_ notification: Notification) {
    savePlaybackState(flush: true)
    timer?.cancel()
    showCursorNow()
    endSleepActivity()
    // 直接退出：mpv 的销毁可能与事件线程互相等待，卡住窗口关不掉
    exit(0)
  }
}

extension NSAlert {
  static func show(_ text: String) {
    let a = NSAlert()
    a.messageText = text
    a.runModal()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var player: Controller?
  private var openSeq = 0
  private var didFinish = false
  private var launchedByDocument = false
  private var documentEventPending = false
  private var openPanel: NSOpenPanel?
  private var pending: [URL] = []

  private enum Target {
    case session(Session)
    case url(URL)
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    didFinish = true
    if let target = Self.commandLineTarget() {
      launchedByDocument = true
      switch target {
      case .session(let s): show(s)
      case .url(let u): open(u)
      }
      return
    }
    if let first = pending.first {
      launchedByDocument = true
      pending.removeAll()
      showOrOpen(first)
      return
    }
    // 双击文件启动时，文稿事件可能比 didFinishLaunching 稍晚到；等一小会儿再弹打开面板
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, self.player == nil, !self.launchedByDocument else { return }
      self.chooseFile()
    }
  }

  // Finder 双击 / 拖到 Dock 图标 / open -a 都会走这里
  func application(_ application: NSApplication, open urls: [URL]) {
    launchedByDocument = true
    documentEventPending = true
    if let panel = openPanel {
      panel.cancel(nil)
      openPanel = nil
    }
    guard let first = urls.first else { return }
    if !didFinish {
      pending.append(contentsOf: urls)
      return
    }
    showOrOpen(first)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if let w = player?.window {
      w.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      chooseFile()
    }
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ n: Notification) {
    player?.savePlaybackState(flush: true)
  }

  // 同一个文件只前置窗口；新文件在同一窗口里切换
  private func showOrOpen(_ url: URL) {
    if let p = player, p.session.file == url.path {
      p.window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    open(url)
  }

  private func open(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      NSAlert.show("文件不存在：\(url.path)")
      if player == nil { NSApp.terminate(nil) }
      return
    }
    openSeq += 1
    let seq = openSeq
    SessionBuilder.make(url) { [weak self] session in
      guard let self, seq == self.openSeq else { return }
      if let session {
        self.show(session)
      } else {
        NSAlert.show("无法打开 \(url.lastPathComponent)")
        if self.player == nil { NSApp.terminate(nil) }
      }
    }
  }

  private func show(_ s: Session) {
    if let p = player {
      p.switchTo(s)
    } else {
      let p = Controller(s)
      player = p
      p.show()
      p.startTimer()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  func chooseFile() {
    if let panel = openPanel {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsOtherFileTypes = true
    panel.allowedContentTypes = [.movie, .audio, .image]
    openPanel = panel
    let resp = panel.runModal()
    openPanel = nil
    if resp == .OK, let url = panel.url {
      launchedByDocument = true
      open(url)
    } else if player == nil && !documentEventPending {
      NSApp.terminate(nil)
    }
  }

  // Electron 仍可按旧格式传 session.json；独立双击时直接传媒体路径
  private static func commandLineTarget() -> Target? {
    for arg in CommandLine.arguments.dropFirst() {
      if arg.hasPrefix("-") { continue }
      if arg.lowercased().hasSuffix(".json"),
         let data = FileManager.default.contents(atPath: arg),
         let s = try? JSONDecoder().decode(Session.self, from: data) {
        return .session(s)
      }
      let u = URL(fileURLWithPath: arg)
      if FileManager.default.fileExists(atPath: u.path) { return .url(u) }
    }
    return nil
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
