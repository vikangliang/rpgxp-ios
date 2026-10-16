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

  /// 清空日志（日志页"清空"按钮）。引擎的 stderr 重定向持有已打开的文件句柄，
  /// 删除文件不会断开它——所以用截断（写入空内容）而非删除，保证引擎继续追加。
  static func clear() {
    let url = docsURL().appendingPathComponent(fileName)
    try? "".write(to: url, atomically: false, encoding: .utf8)
  }
}
