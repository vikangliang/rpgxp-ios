import Flutter
import UIKit
import AVFAudio
import ObjectiveC

/// mkxp 插件的 iOS 入口。由 GeneratedPluginRegistrant 自动调用 register(with:)，
/// 负责注册 MethodChannel 与平台视图工厂。无需修改 AppDelegate。
public class MkxpPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    installCrashLogger()
    installAudioResume()
    installOrientationMask()

    let channel = FlutterMethodChannel(name: "com.yourapp.mkxp",
                                        binaryMessenger: registrar.messenger())
    MkxpMethodHandler.channel = channel
    let handler = MkxpMethodHandler()
    channel.setMethodCallHandler(handler.handle)

    let factory = MkxpPlatformViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "mkxp-game-view")
  }

  /// 后台返回后 SDL/CoreAudio 的会话常被系统重置（实测：切出再回来 BGM+音效全无），
  /// 前台恢复时重新激活 AVAudioSession 兜底。
  private static func installAudioResume() {
    NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil, queue: .main) { _ in
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        MkxpLog.append("[audio] foreground: AVAudioSession reactivated")
      } catch {
        MkxpLog.append("[audio] foreground reactivate failed: \(error)")
      }
    }
  }
}

/// 崩溃日志器：NSException 一类的崩溃（如后台线程触碰 UIKit 抛出的
/// NSInternalInconsistencyException）在终止前把**符号化调用栈**写进
/// mkxp.log——无 Xcode 环境下这是唯一能定位崩溃点的手段。
private func installCrashLogger() {
  NSSetUncaughtExceptionHandler { ex in
    var lines = ["", "[crash] \(ex.name.rawValue): \(ex.reason ?? "")"]
    lines.append(contentsOf: ex.callStackSymbols.map { "[crash] \($0)" })
    MkxpLog.append(lines.joined(separator: "\n"))
  }
}

/// MethodChannel 处理器。M1：launch/quit/key 已接 MKXP.framework；
/// listGames/importZip 等属 M2。
class MkxpMethodHandler: NSObject {
  /// 原生浮层「退出游戏」时反向通知 Flutter 复位 preferred orientations。
  /// 用 strong 持有：FlutterMethodChannel 只作为 messenger 上的名字存在，
  /// register 返回后局部量会被释放。
  static var channel: FlutterMethodChannel?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listGames":
      result([]) // M2 扫描 Documents/games
    case "readLog":
      result(MkxpLog.readTail())
    case "listSceneDumps":
      result(MkxpSceneDumps.list())
    case "readSceneDump":
      guard let args = call.arguments as? [String: Any],
            let name = args["name"] as? String,
            name.hasPrefix("scene_dump_"), name.hasSuffix(".png"),
            !name.contains("/") else {
        result(FlutterError(code: "badArgs", message: "readSceneDump 需要合法的 scene_dump_*.png 文件名", details: nil))
        return
      }
      let url = MkxpLog.docsURL().appendingPathComponent(name)
      result(FlutterStandardTypedData(bytes: (try? Data(contentsOf: url)) ?? Data()))
    case "launch":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "badArgs",
                            message: "launch 需要非空 path（游戏目录，相对则按 Documents 解析）",
                            details: nil))
        return
      }
      // 音频会话：.playback 绕过静音拨片。必须在【主线程】配置——AVAudioSession
      // 的 setActive 若跑到后台队列，会和 SDL 的音频初始化并发抢同一会话，
      // 真机常在 BGM 真正出声后几秒崩溃（表现为“画面+BGM 隔几秒重启”）。
      MkxpLog.append("[launch] 激活音频会话(主线程)…")
      DispatchQueue.main.async {
        do {
          let s = AVAudioSession.sharedInstance()
          try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
          try s.setActive(true)
          MkxpLog.append("[launch] AVAudioSession .playback OK")
        } catch {
          MkxpLog.append("[launch] AVAudioSession 失败: \(error)")
        }
      }
      MkxpLog.append("[launch] 调 mkxp_run(\(path))")
      // 启动前修复 zip 导入产生的乱码文件名（GBK 名被 Latin-1 误解码，
      // 会导致中文名 BGM/贴图找不到：切图 BGM 静音、精灵显示"?"）
      MkxpFileFix.normalize(URL(fileURLWithPath: MkxpBridge.resolve(path)))
      let rc = MkxpBridge.run(gamePath: path)
      if rc == 0 {
        MkxpTouchOverlay.shared.show()       // 原生触摸浮层（SDL 窗口之上）
        MkxpTouchOverlay.shared.showLoading() // “启动中”HUD（引擎出首帧自动收起）
        result(nil)
      } else {
        result(FlutterError(code: "runFailed",
                            message: "mkxp_run 返回 \(rc)（-2=已在运行 -3=目录不存在）",
                            details: nil))
      }
    case "quit":
      MkxpOrientation.endGame()
      MkxpBridge.quit()
      MkxpTouchOverlay.shared.hide()
      result(nil)
    case "key":
      guard let args = call.arguments as? [String: Any],
            let k = args["k"] as? Int,
            let down = args["down"] as? Bool else {
        result(FlutterError(code: "badArgs", message: "key 需要 k/down 参数", details: nil))
        return
      }
      MkxpBridge.key(k, down: down)
      result(nil)
    case "importZip":
      result(nil) // M2 由原生扫描/解压，占位
    case "showControls":
      MkxpTouchOverlay.shared.show(); result(nil)
    case "hideControls":
      MkxpTouchOverlay.shared.hide(); result(nil)
    case "toggleControls":
      MkxpTouchOverlay.shared.toggle(); result(nil)
    case "setOrientation":
      // 游戏方向只由设置「固定横屏游戏」传入；布尔桥接失败时不能静默忽略，
      // 否则会停在上一局的方向。用兼容解析并显式回退到竖屏。
      // active=false 表示退出游戏（Dart _cleanup），收敛到同一入口复位。
      let args = call.arguments as? [String: Any]
      if mkxpBool(args, "active", true) {
        MkxpOrientation.setGameOrientation(landscape: mkxpBool(args, "landscape", false))
      } else {
        MkxpOrientation.endGame()
      }
      result(nil)
    case "haptic":
      MkxpHaptic.tap(); result(nil)
    case "setKeepAwake":
      if let args = call.arguments as? [String: Any],
         let on = args["on"] as? Bool {
        UIApplication.shared.isIdleTimerDisabled = on
      }
      result(nil)
    case "clearLog":
      MkxpLog.clear(); result(nil)
    case "engineReady":
      result(MkxpBridge.firstFrameShown())
    case "getFps":
      result(MkxpBridge.fps())

    // MARK: - 虚拟按键布局（横竖各一套，运行时可调，无需重新打包）
    case "getControlLayout":
      let args = call.arguments as? [String: Any]
      let landscape = mkxpBool(args, "landscape", true)
      let size = MkxpControlLayout.canvasSize(landscape: landscape)
      let payload: [String: Any] = ["items": MkxpControlLayout.load(landscape: landscape),
                                    "defaults": MkxpControlLayout.defaults(landscape: landscape),
                                    "customized": MkxpControlLayout.hasCustom(landscape: landscape),
                                    "canvasW": Double(size.width),
                                    "canvasH": Double(size.height)]
      result(payload)
    case "setControlLayout":
      guard let args = call.arguments as? [String: Any],
            let raw = args["items"] as? [Any] else {
        result(FlutterError(code: "badArgs", message: "setControlLayout 需要 items 数组", details: nil))
        return
      }
      let landscape = mkxpBool(args, "landscape", true)
      let items = raw.compactMap { $0 as? [String: Any] }
      MkxpControlLayout.save(items, landscape: landscape)
      // 游戏运行中，只有编辑的正是当前方向时才会立刻看到变化；另一套在旋转后生效。
      MkxpTouchOverlay.shared.applyLayout()
      result(nil)
    case "resetControlLayout":
      let args = call.arguments as? [String: Any]
      let landscape = mkxpBool(args, "landscape", true)
      MkxpControlLayout.reset(landscape: landscape)
      MkxpTouchOverlay.shared.applyLayout()   // 回到该方向的原始硬编码布局（重置起点）
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// MethodChannel 的 bool 可能桥接成 NSNumber/__NSCFBoolean，统一解析，
/// 避免 `as? Bool` 失败时静默回退 true（那会让「竖屏」永远读到横屏配置）。
private func mkxpBool(_ args: [String: Any]?, _ key: String, _ fallback: Bool) -> Bool {
  if let n = args?[key] as? NSNumber { return n.boolValue }
  if let b = args?[key] as? Bool { return b }
  if let s = args?[key] as? String { return s == "true" || s == "1" }
  return fallback
}

// MARK: - 场景快照（ios_embed.mm 落盘的 Documents/scene_dump_*.png）
enum MkxpSceneDumps {
  static func list() -> [[String: Any]] {
    let fm = FileManager.default
    let dir = MkxpLog.docsURL()
    let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
    var out: [[String: Any]] = []
    for name in names where name.hasPrefix("scene_dump_") && name.hasSuffix(".png") {
      let path = dir.appendingPathComponent(name).path
      let attr = (try? fm.attributesOfItem(atPath: path)) ?? [:]
      let size = (attr[.size] as? NSNumber)?.intValue ?? 0
      let mtime = (attr[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
      out.append(["name": name, "size": size, "mtime": mtime])
    }
    return out.sorted { ($0["mtime"] as? Int ?? 0) > ($1["mtime"] as? Int ?? 0) }
  }
}

// MARK: - 文件名编码修复
/// Windows 压缩的 zip 文件名常为 GBK 编码且不带 UTF-8 标志，Dart 的 archive 包
/// 按 Latin-1 解码 → 落盘成乱码名。后果实测：中文名 BGM（如 真新镇.ogg）找不到
/// → 切图后 BGM 静音；中/日文名贴图找不到 → 精灵显示"?"。
/// 这里在每次启动游戏前扫描游戏目录，把"纯 Latin-1 扩展区"名字按 GB18030
/// 重新解码并改名（严格启发式，绝不误伤合法的 é 等西文字符）。
enum MkxpFileFix {
  private static let gb18030 = String.Encoding(rawValue:
      CFStringConvertEncodingToNSStringEncoding(
          CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

  static func normalize(_ dir: URL) {
    ensureConfig(dir)
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
    var dirs: [URL] = []
    var files: [URL] = []
    for case let url as URL in enumerator {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
        dirs.append(url)
      } else {
        files.append(url)
      }
    }
    // 先文件后目录；目录按深度降序（自底向上改，父路径才有效）
    for url in files { fixName(url) }
    for url in dirs.sorted(by: { $0.path.components(separatedBy: "/").count
                                > $1.path.components(separatedBy: "/").count }) {
      fixName(url)
    }
  }

  /// 写入引擎配置（mkxp.json 从游戏目录读取）。仅在不存在时写，避免覆盖用户改动。
  /// SESourceCount：真实 RGSS1 运行时的 SE 并发远多于 mkxp 默认的 6，
  /// 密集战斗/事件时超出会被静默丢弃（表现为“音效偶尔缺失”）。
  private static func ensureConfig(_ dir: URL) {
    let path = dir.appendingPathComponent("mkxp.json")
    let fm = FileManager.default
    guard !fm.fileExists(atPath: path.path) else { return }
    let json = """
    {
      "SESourceCount": 24,
      "pathCache": true,
      "winResizable": false
    }
    """
    fm.createFile(atPath: path.path, contents: json.data(using: .utf8))
    MkxpLog.append("[file-fix] mkxp.json written (SESourceCount=24)")
  }

  private static func fixName(_ url: URL) {
    guard let fixed = repaired(url.lastPathComponent) else { return }
    let target = url.deletingLastPathComponent().appendingPathComponent(fixed)
    let fm = FileManager.default
    guard !fm.fileExists(atPath: target.path) else { return }
    do {
      try fm.moveItem(at: url, to: target)
      MkxpLog.append("[file-fix] \(url.lastPathComponent) -> \(fixed)")
    } catch {
      MkxpLog.append("[file-fix] rename failed: \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  /// 名字全部由 ≤0xFF 的标量组成且含扩展区字符（≥0x80）→ 乱码候选；
  /// GB18030 解码成功、结果不同、且中日韩字符占比 ≥50% → 改名。
  /// （"Pokémon" 的 é 虽是候选，但其 GB18030 误解码里 CJK 占比过低，不会命中。）
  static func repaired(_ name: String) -> String? {
    var hasHigh = false
    for sc in name.unicodeScalars {
      let v = sc.value
      if v > 0xFF { return nil }
      if v >= 0x80 { hasHigh = true }
    }
    guard hasHigh else { return nil }
    let bytes = name.unicodeScalars.compactMap { $0.value <= 0xFF ? UInt8($0.value) : nil }
    guard let decoded = String(data: Data(bytes), encoding: gb18030),
          decoded != name else { return nil }
    var cjk = 0
    for sc in decoded.unicodeScalars
    where (0x4E00...0x9FFF).contains(sc.value) || (0x3040...0x30FF).contains(sc.value) {
      cjk += 1
    }
    guard cjk * 2 >= decoded.count else { return nil }
    return decoded
  }
}

// MARK: - 横竖屏锁定（M2 设置：固定横屏游戏）

/// 浮层窗口的 rootVC：动态返回持久方向掩码。裸 UIViewController 默认
/// .allButUpsideDown，controlsWindow 成为 key window 后会架空 Flutter 的方向锁。
final class MkxpOrientationRootViewController: UIViewController {
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { MkxpOrientation.mask }
  override var shouldAutorotate: Bool { true }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
    MkxpOrientation.isLandscape ? .landscapeRight : .portrait
  }
}

/// 方向状态的唯一数据源。旧的 lockLandscape 只是「一次性旋转请求」，设备一转
/// 系统就按 key window / Info.plist 重新选方向 → 跟着手机转。现在改为持久掩码：
/// AppDelegate 层（对所有窗口生效）+ 三个浮层 rootVC + 一次性 geometry 请求。
final class MkxpOrientation {
  /// 仅主线程读写（MethodChannel / UIKit 回调都在主线程）。
  private(set) static var isLandscape = false
  private(set) static var gameActive = false

  static var mask: UIInterfaceOrientationMask {
    isLandscape ? .landscape : .portrait
  }

  static func makeRootViewController() -> UIViewController {
    MkxpOrientationRootViewController()
  }

  /// 进游戏：写入开关决定的方向，并立刻让系统重新评估。
  static func setGameOrientation(landscape: Bool) {
    gameActive = true
    isLandscape = landscape
    apply()
  }

  /// 退出游戏：复位为 App 默认竖屏（不残留上一局方向）。
  static func endGame() {
    gameActive = false
    isLandscape = false
    apply()
  }

  /// 让系统按新掩码重新评估方向。geometry 请求带 errorHandler，
  /// 方向白名单不含目标方向时只记日志，不抛异常崩溃。
  static func apply() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { apply() }
      return
    }
    let target = mask
    if !orientationMaskInstalled { installOrientationMask() }
    if #available(iOS 16.0, *) {
      for scene in UIApplication.shared.connectedScenes {
        guard let ws = scene as? UIWindowScene else { continue }
        for win in ws.windows {
          win.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
      }
    }
    let ori: UIDeviceOrientation = isLandscape ? .landscapeRight : .portrait
    UIDevice.current.setValue(ori.rawValue, forKey: "orientation")
    UIViewController.attemptRotationToDeviceOrientation()
    if #available(iOS 16.0, *) {
      let scene = UIApplication.shared.connectedScenes
        .first { $0.activationState == .foregroundActive } as? UIWindowScene
      let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: target)
      scene?.requestGeometryUpdate(prefs) { error in
        MkxpLog.append("[orientation] geometry update rejected: \(error.localizedDescription)")
      }
    }
  }
}

/// App 里有 Flutter / SDL / 3 个浮层多个 UIWindow，iOS 会按 key window 询问方向；
/// 任一窗口放开就会随设备转。AppDelegate 由 CI 的 flutter create 生成、不入库，
/// 因此运行时注入 application:supportedInterfaceOrientationsForWindow:：
/// 已实现则替换 IMP，未实现则补上，统一返回持久掩码。
private var orientationMaskInstalled = false
private func installOrientationMask() {
  guard !orientationMaskInstalled else { return }
  // register 时 delegate 可能尚未就绪；不在此时置位，由 apply() 再兜底安装。
  guard let delegate = UIApplication.shared.delegate else { return }
  orientationMaskInstalled = true
  let cls: AnyClass = type(of: delegate)
  let sel = NSSelectorFromString("application:supportedInterfaceOrientationsForWindow:")
  let block: @convention(block) (AnyObject, UIApplication, UIWindow?) -> UInt = { _, _, _ in
    UInt(MkxpOrientation.mask.rawValue)
  }
  let imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
  // NSUInteger (*)(id, SEL, UIApplication *, UIWindow *)
  let types = "Q@:@@"
  if !class_addMethod(cls, sel, imp, types) {
    if let m = class_getInstanceMethod(cls, sel) { method_setImplementation(m, imp) }
  }
  MkxpLog.append("[orientation] persistent mask installed")
}

// MARK: - 控制器振动（M2 设置：控制器振动）
final class MkxpHaptic {
  static func tap() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}
