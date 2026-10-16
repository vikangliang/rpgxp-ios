import Flutter
import UIKit

/// mkxp 插件的 iOS 入口。由 GeneratedPluginRegistrant 自动调用 register(with:)，
/// 负责注册 MethodChannel 与平台视图工厂。无需修改 AppDelegate。
public class MkxpPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.yourapp.mkxp",
                                        binaryMessenger: registrar.messenger())
    let handler = MkxpMethodHandler()
    channel.setMethodCallHandler(handler.handle)

    let factory = MkxpPlatformViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "mkxp-game-view")
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
    case "launch":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "badArgs",
                            message: "launch 需要非空 path（游戏目录，相对则按 Documents 解析）",
                            details: nil))
        return
      }
      let rc = MkxpBridge.run(gamePath: path)
      if rc == 0 {
        MkxpTouchOverlay.shared.show()   // M2 阶段二：引擎起后展示原生触摸浮层
        result(nil)
      } else {
        result(FlutterError(code: "runFailed",
                            message: "mkxp_run 返回 \(rc)（-2=已在运行 -3=目录不存在）",
                            details: nil))
      }
    case "quit":
      MkxpBridge.quit()
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
    default:
      result(FlutterMethodNotImplemented)
    }
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
