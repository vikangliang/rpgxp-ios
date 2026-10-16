import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 一个已安装的游戏。
class GameInfo {
  final String name;
  final String dirPath;
  final String? iconPath; // 游戏根目录的 Icon.png（RPG Maker XP 默认图标）
  const GameInfo(this.name, this.dirPath, {this.iconPath});
}

/// 游戏库（M2）：扫描 Documents/games/ 下的游戏，支持从 Zip 导入解压。
///
/// 数据流：Zip（file_picker 选择）→ archive 解压 → <Documents>/games/<名>/
/// → Mkxp.launchGame('games/<名>')（原生侧按 Documents 解析相对路径）。
class GameLibrary {
  /// 游戏根目录 <Documents>/games（不存在则创建）。
  static Future<Directory> gamesDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/games');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 扫描：games/ 下顶层含 Game.ini 的子目录即为一个游戏。
  /// 图标取游戏根的 Icon.png（RPG Maker XP 工程默认生成）。
  static Future<List<GameInfo>> scan() async {
    final dir = await gamesDir();
    final games = <GameInfo>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        if (await File('${entity.path}/Game.ini').exists()) {
          final name = entity.path.split('/').last;
          final icon = File('${entity.path}/Icon.png');
          games.add(GameInfo(name, entity.path,
              iconPath: await icon.exists() ? icon.path : null));
        }
      }
    }
    games.sort((a, b) => a.name.compareTo(b.name));
    return games;
  }

  /// 删除游戏目录。
  static Future<void> delete(String name) async {
    final dir = await gamesDir();
    final target = Directory('${dir.path}/$name');
    if (await target.exists()) await target.delete(recursive: true);
  }

  /// 导入 Zip：选择文件 → 解压到 games/<名>/，返回游戏名（取消返回空串）。
  ///
  /// onProgress：(0.0~1.0 进度按未压缩字节计, 当前文件名)。约 80ms 节流
  /// 一次，解压结束必报一次——大 Zip（Essentials 数百 MB/数千文件）不再只有
  /// 一个转圈。
  ///
  /// 自动定位游戏根（含 Game.ini 的那一层），同时兼容两种打包方式：
  ///   - Game.ini 在 Zip 根目录（整包直铺）；
  ///   - Game.ini 在 Zip 内的某个文件夹下（常见：Essentials/Game.ini）。
  /// 自动跳过 __MACOSX/、.DS_Store、._* 等 macOS 打包垃圾。
  static Future<String> importZip(
      {void Function(double progress, String currentFile)? onProgress}) async {
    // file_picker 13.x：FilePicker 是 abstract final class，静态方法直接挂在
    // FilePicker 上（无 .platform 成员），单文件选择用 pickFile()，读取数据
    // 改用 PlatformFile.readAsBytes()。
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null) return '';

    final bytes = await picked.readAsBytes();
    if (bytes == null || bytes.isEmpty) {
      throw Exception('无法读取所选文件');
    }

    final archive = ZipDecoder().decodeBytes(bytes);

    // 1) 定位游戏根：哪个条目是 Game.ini，其上层层级就是根前缀
    var rootPrefix = '';
    for (final f in archive) {
      if (!f.isFile) continue;
      final p = f.name.replaceAll(r'\', '/');
      if (p.toLowerCase().endsWith('game.ini')) {
        rootPrefix = p.substring(0, p.length - 'game.ini'.length);
        break;
      }
    }

    // 2) 目标名：优先根文件夹名，否则用 Zip 文件名（去 .zip）
    var name = '';
    if (rootPrefix.isNotEmpty) {
      final segs = rootPrefix.split('/').where((s) => s.isNotEmpty);
      if (segs.isNotEmpty) name = segs.last;
    }
    if (name.isEmpty) {
      name = picked.name;
      if (name.toLowerCase().endsWith('.zip')) {
        name = name.substring(0, name.length - 4);
      }
    }
    name = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    if (name.isEmpty) name = 'game';

    // 3) 解压（跳过打包垃圾与根目录之外的文件），按字节上报进度
    final dir = await gamesDir();
    final dest = Directory('${dir.path}/$name');
    if (await dest.exists()) await dest.delete(recursive: true);
    await dest.create(recursive: true);

    var totalBytes = 0;
    for (final f in archive) {
      if (f.isFile) totalBytes += f.size.toInt();
    }
    var written = 0;
    var lastTick = DateTime.now();
    void report(String file, {bool force = false}) {
      if (onProgress == null) return;
      final now = DateTime.now();
      if (!force && now.difference(lastTick).inMilliseconds < 80) return;
      lastTick = now;
      onProgress(totalBytes == 0 ? 1.0 : written / totalBytes, file);
    }

    for (final f in archive) {
      written += f.size.toInt(); // 跳过的文件也计入总量，保证进度单调
      if (!f.isFile) continue;
      var p = f.name.replaceAll(r'\', '/');
      if (p.startsWith('__MACOSX/')) continue;
      final base = p.split('/').last;
      if (base == '.DS_Store' || base.startsWith('._')) continue;
      if (rootPrefix.isNotEmpty) {
        if (!p.startsWith(rootPrefix)) continue;
        p = p.substring(rootPrefix.length);
      }
      if (p.isEmpty) continue;
      report(p);
      final data = f.content;
      if (data == null) continue;
      final out = File('${dest.path}/$p');
      await out.create(recursive: true);
      await out.writeAsBytes(data);
    }
    report('完成', force: true);

    // 4) 校验：顶层必须有 Game.ini，否则不是 RGSS 游戏
    if (!await File('${dest.path}/Game.ini').exists()) {
      throw Exception('解压完成但没找到 Game.ini——这个 Zip 可能不是 RPG Maker XP 游戏');
    }
    return name;
  }
}
