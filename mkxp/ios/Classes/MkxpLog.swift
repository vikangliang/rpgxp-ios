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
}
