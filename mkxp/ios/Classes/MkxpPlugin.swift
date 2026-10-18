import Flutter
import UIKit
import AVFAudio

/// mkxp 插件的 iOS 入口。由 GeneratedPluginRegistrant 自动调用 register(with:)，
/// 负责注册 MethodChannel 与平台视图工厂。无需修改 AppDelegate。
public class MkxpPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    installCrashLogger()

    let channel = FlutterMethodChannel(name: "com.yourapp.mkxp",
                                        binaryMessenger: registrar.messenger())
    let handler = MkxpMethodHandler()
    channel.setMethodCallHandler(handler.handle)

    let factory = MkxpPlatformViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "mkxp-game-view")
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
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listGames":
      result([]) // M2 扫描 Documents/games
    case "readLog":
      result(MkxpLog.readBootstrapLog())
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
      if let args = call.arguments as? [String: Any],
         let landscape = args["landscape"] as? Bool {
        MkxpOrientation.lockLandscape(landscape)
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
    default:
      result(FlutterMethodNotImplemented)
    }
  }
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
      CFStringConvertEncodingToNSStringEncoding(CFStringEncodings.GB_18030_2000))

  static func normalize(_ dir: URL) {
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
final class MkxpOrientation {
  static func lockLandscape(_ on: Bool) {
    let ori: UIDeviceOrientation = on ? .landscapeRight : .portrait
    UIDevice.current.setValue(ori.rawValue, forKey: "orientation")
    UIViewController.attemptRotationToDeviceOrientation()
    if #available(iOS 16.0, *) {
      let scene = UIApplication.shared.connectedScenes
        .first { $0.activationState == .foregroundActive } as? UIWindowScene
      scene?.requestGeometryUpdate(.iOS(interfaceOrientations: on ? .landscapeRight : .portrait))
    }
  }
}

// MARK: - 控制器振动（M2 设置：控制器振动）
final class MkxpHaptic {
  static func tap() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}
