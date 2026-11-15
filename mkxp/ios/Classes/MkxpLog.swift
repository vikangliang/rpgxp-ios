import Foundation

/// 无 Mac 环境下的调试代偿：把关键日志写入 App 沙盒 Documents/mkxp.log，
/// Flutter 日志页读取它，相当于“远程控制台”。引擎/桥接的报错都往这里写。
struct MkxpLog {
  static let fileName = "mkxp.log"

  static func docsURL() -> URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  /// 追加一行日志（带时间戳）。
  static func append(_ text: String) {
    let url = docsURL().appendingPathComponent(fileName)
    let line = "\(Date()) \(text)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(line.data(using: .utf8)!)
      try? handle.close()
    } else {
      try? line.write(to: url, atomically: true, encoding: .utf8)
    }
  }

  static func writeBootstrapLog() {
    append("[M0] bootstrap OK — Flutter→native→file 链路通")
  }

  static func readBootstrapLog() -> String {
    let url = docsURL().appendingPathComponent(fileName)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? "（无日志文件）"
  }

  /// 读取日志【末尾】最多 maxBytes 字节（避免大文件整文件读入内存导致闪退）。
  /// 用 FileHandle 只 seek 末尾一段，即使 mkxp.log 被撑到很大也只加载尾部。
  static func readTail(maxBytes: Int = 256 * 1024) -> String {
    let url = docsURL().appendingPathComponent(fileName)
    guard let fh = try? FileHandle(forReadingFrom: url) else { return "（无日志文件）" }
    defer { try? fh.close() }
    let total = (try? fh.seekToEnd()) ?? 0
    guard total > 0 else { return "（日志为空）" }
    let skip = max(0, Int(total) - maxBytes)
    fh.seek(toFileOffset: UInt64(skip))
    let len = Int(total) - skip
    guard let chunk = try? fh.read(upToCount: len), chunk.count > 0 else { return "（日志为空）" }
    // 跳过首个可能不完整的行
    var s = chunk.startIndex
    if let nl = chunk.firstIndex(of: 10) { s = chunk.index(after: nl) }
    let tail = chunk.subdata(in: s..<chunk.endIndex)
    var str = String(data: tail, encoding: .utf8) ?? "（日志解码失败）"
    if skip > 0 { str = "…（已省略早期 \(skip) 字节，仅显示末尾）…\n" + str }
    return str
  }

  /// 清空日志（日志页"清空"按钮）。引擎的 stderr 重定向持有已打开的文件句柄，
  /// 删除文件不会断开它——所以用截断（写入空内容）而非删除，保证引擎继续追加。
  static func clear() {
    let url = docsURL().appendingPathComponent(fileName)
    try? "".write(to: url, atomically: false, encoding: .utf8)
  }

  /// 解析 mkxp.log 末尾最后一个 `[diag] <json>` 行（Ruby 诊断器输出），返回字典。
  /// Flutter 诊断页与 HUD 浮层据此展示帧耗时/慢帧归因/闪退，无需读整个大文件。
  static func readLastDiag() -> [String: Any]? {
    let tail = readTail()
    for line in tail.components(separatedBy: "\n").reversed() {
      guard let range = line.range(of: "[diag] "), range.upperBound < line.endIndex else { continue }
      let jsonStr = String(line[range.upperBound...])
      guard let data = jsonStr.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      return obj
    }
    return nil
  }

  /// 解析最近一条**引擎侧**帧分解埋点（ios_embed.mm 的 PROFILE / main-display / hook avg）。
  ///
  /// 为什么需要它：Ruby 侧 `[diag]` 只统计**脚本/绘制逻辑**（实测仅 ~0.2ms/帧），
  /// 完全不含 iOS 软呈现层的开销。真实帧周期由引擎埋点给出：
  ///   frame = 帧间隔；engine ≈ 帧间隔 − read − hmc（含等 vsync 的等待）；
  ///   read = glFinish+glReadPixels 的 GPU→CPU 回读；hmc = 哈希+memcpy+CGImage；
  ///   disp = 主线程放大上屏；mainDisp = 主线程显示总耗时。
  /// 这些埋点由 MKXP_DIAG 门控（与诊断开关同开同关），每 600 帧打印一行。
  static func readLastEngineProfile() -> [String: Any]? {
    let tail = readTail()

    let profRe = try? NSRegularExpression(
      pattern: #"PROFILE fps=([0-9.]+) frame=([0-9.]+)ms \[engine=([0-9.]+) read=([0-9.]+) hmc=([0-9.]+) disp=([0-9.]+)\]"#)
    let dispRe = try? NSRegularExpression(pattern: #"main-display avg ([0-9.]+) ms"#)
    let hookRe = try? NSRegularExpression(
      pattern: #"hook avg ([0-9.]+) max ([0-9.]+) \| present max ([0-9.]+) \| soft max ([0-9.]+)"#)

    func d(_ line: String, _ m: NSTextCheckingResult, _ i: Int) -> Double {
      let r = m.range(at: i)
      guard r.location != NSNotFound, let sr = Range(r, in: line) else { return 0 }
      return Double(String(line[sr])) ?? 0
    }

    var prof: [String: Any] = [:]
    for line in tail.components(separatedBy: "\n").reversed() {
      guard line.contains("[ios-embed]") else { continue }
      let ns = NSRange(line.startIndex..., in: line)

      if prof["frameMs"] == nil, let re = profRe,
         let m = re.firstMatch(in: line, range: ns) {
        prof["fps"] = d(line, m, 1)
        prof["frameMs"] = d(line, m, 2)
        prof["engine"] = d(line, m, 3)
        prof["read"] = d(line, m, 4)
        prof["hmc"] = d(line, m, 5)
        prof["disp"] = d(line, m, 6)
      }
      if prof["mainDispMs"] == nil, let re = dispRe,
         let m = re.firstMatch(in: line, range: ns) {
        prof["mainDispMs"] = d(line, m, 1)
      }
      if prof["softMaxMs"] == nil, let re = hookRe,
         let m = re.firstMatch(in: line, range: ns) {
        prof["hookAvgMs"] = d(line, m, 1)
        prof["hookMaxMs"] = d(line, m, 2)
        prof["presentMaxMs"] = d(line, m, 3)
        prof["softMaxMs"] = d(line, m, 4)
      }
      if !prof.isEmpty { return prof }
    }
    return nil
  }
}
