import Flutter
import UIKit

class MkxpPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    MkxpPlatformView(frame: frame, viewId: viewId, args: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

class MkxpPlatformView: NSObject, FlutterPlatformView {
  private let _view: UIView

  init(frame: CGRect, viewId: Int64, args: Any?) {
    _view = UIView(frame: frame)
    _view.backgroundColor = .black
    // M0：仅写入启动日志，验证 Flutter→原生→文件 链路。
    // M1 将在此调用 MkxpBridge 启动 MKXP 引擎并渲染到 _view。
    MkxpLog.writeBootstrapLog()
    super.init()
  }

  func view() -> UIView { _view }
}
