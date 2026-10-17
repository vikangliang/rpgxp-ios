import Flutter
import UIKit

// 引擎侧 C 符号：注入 Flutter 提供的宿主 UIView，SDL 渲染视图会搬进它。
@_silgen_name("mkxp_ios_setHostView")
private func mkxp_ios_setHostView(_ view: UnsafeMutableRawPointer)

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
    // 把宿主 UIView 交给引擎：SDL 建窗后会把渲染视图搬进它，画面在 PlatformView 里出像素。
    let ptr = Unmanaged.passUnretained(_view).toOpaque()
    mkxp_ios_setHostView(ptr)
    MkxpLog.append("[platform] setHostView _view=\(ptr)")
    // M0：仅写入启动日志，验证 Flutter→原生→文件 链路。
    // M1 将在此调用 MkxpBridge 启动 MKXP 引擎并渲染到 _view。
    MkxpLog.writeBootstrapLog()
    super.init()
  }

  func view() -> UIView { _view }
}
