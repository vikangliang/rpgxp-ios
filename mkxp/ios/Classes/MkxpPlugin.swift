import Flutter
import UIKit

/// mkxp 插件的 iOS 入口。由 GeneratedPluginRegistrant 自动调用 register(with:)，
/// 负责注册 MethodChannel 与平台视图工厂。无需修改 AppDelegate。
public class MkxpPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.yourapp.mkxp",
                                        binaryMessenger: registrar.messenger)
    let handler = MkxpMethodHandler()
    channel.setMethodCallHandler(handler.handle)

    let factory = MkxpPlatformViewFactory(messenger: registrar.messenger)
    registrar.registerViewFactory(factory, withId: "mkxp-game-view")
  }
}

/// MethodChannel 处理器（M0 占位，M1/M2 填充真实逻辑）
class MkxpMethodHandler: NSObject {
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "listGames":
      result([]) // M2 扫描 Documents/games
    case "readLog":
      result(MkxpLog.readBootstrapLog())
    case "importZip", "launch", "key", "setOrientation", "haptic":
      result(nil) // M0 占位
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
