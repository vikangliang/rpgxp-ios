import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 一个已安装的游戏。
class GameInfo {
  final String name;
  final String dirPath;
  const GameInfo(this.name, this.dirPath);
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
  static Future<List<GameInfo>> scan() async {
    final dir = await gamesDir();
    final games = <GameInfo>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        if (await File('${entity.path}/Game.ini').exists()) {
          final name = entity.path.split('/').last;
          games.add(GameInfo(name, entity.path));
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
  /// 自动定位游戏根（含 Game.ini 的那一层），同时兼容两种打包方式：
  ///   - Game.ini 在 Zip 根目录（整包直铺）；
  ///   - Game.ini 在 Zip 内的某个文件夹下（常见：Essentials/Game.ini）。
  /// 自动跳过 __MACOSX/、.DS_Store、._* 等 macOS 打包垃圾。
  static Future<String> importZip() async {
    // file_picker 13.x：单文件选择用 pickFile()（pickFiles 的 withData/
    // allowMultiple 已被移除），读取数据改用 PlatformFile.readAsBytes()。
    final picked = await FilePicker.platform.pickFile(type: FileType.any);
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

    // 3) 解压（跳过打包垃圾与根目录之外的文件）
    final dir = await gamesDir();
    final dest = Directory('${dir.path}/$name');
    if (await dest.exists()) await dest.delete(recursive: true);
    await dest.create(recursive: true);

    for (final f in archive) {
      if (!f.isFile) continue;
      final data = f.content;
      if (data == null) continue;
      var p = f.name.replaceAll(r'\', '/');
      if (p.startsWith('__MACOSX/')) continue;
      final base = p.split('/').last;
      if (base == '.DS_Store' || base.startsWith('._')) continue;
      if (rootPrefix.isNotEmpty) {
        if (!p.startsWith(rootPrefix)) continue;
        p = p.substring(rootPrefix.length);
      }
      if (p.isEmpty) continue;
      final out = File('${dest.path}/$p');
      await out.create(recursive: true);
      await out.writeAsBytes(data);
    }

    // 4) 校验：顶层必须有 Game.ini，否则不是 RGSS 游戏
    if (!await File('${dest.path}/Game.ini').exists()) {
      throw Exception('解压完成但没找到 Game.ini——这个 Zip 可能不是 RPG Maker XP 游戏');
    }
    return name;
  }
}
