import Foundation
import MKXP

/// MKXP.framework 的 C 接口薄封装。
/// 实现见 scripts/mkxp-framework/mkxp_framework.cpp：mkxp_run 在后台线程启动
/// 引擎（SDL 自建全屏窗口）并立即返回，因此本类的调用都是非阻塞的。
enum MkxpBridge {
  /// 启动引擎。gamePath 为游戏目录，相对路径按沙盒 Documents 解析
  /// （M2 的导入解压目标目录）。
  /// 返回 0 成功；-1 参数为空；-2 引擎已在运行；-3 目录不存在。
  @discardableResult
  static func run(gamePath: String) -> Int32 {
    let abs = resolve(gamePath)
    MkxpLog.append("[bridge] mkxp_run(\(abs))")
    let rc = abs.withCString { mkxp_run($0) }
    MkxpLog.append("[bridge] mkxp_run -> \(rc)")
    return rc
  }

  /// 注入 RGSS 按键（Input::ButtonCode：下=2 左=4 右=6 上=8，
  /// A=11 B=12 C=13 X=14 Y=15 Z=16 L=17 R=18 F5=25…）。down 为是否按下。
  static func key(_ rgssKey: Int, down: Bool) {
    MkxpLog.append("[key] k=\(rgssKey) down=\(down)")
    mkxp_key(Int32(rgssKey), down ? 1 : 0)
  }

  /// 请求关机：走 SDL_QUIT 正常清理流程，引擎线程随后退出。
  static func quit() {
    MkxpLog.append("[bridge] mkxp_quit")
    mkxp_quit()
  }

  /// 引擎是否已把第一帧画面送上屏（Flutter 加载提示据此收起）。
  static func firstFrameShown() -> Bool {
    mkxp_ios_firstFrameShown() != 0
  }

  /// 实时平均帧率（FPS 角标用）。
  static func fps() -> Double {
    mkxp_get_avg_fps()
  }

  /// 相对路径统一解析到 App 沙盒 Documents 下。
  static func resolve(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    return docs.hasSuffix("/") ? docs + path : docs + "/" + path
  }
}
