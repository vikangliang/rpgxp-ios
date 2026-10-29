import 'package:flutter/material.dart';

import '../services/game_library.dart';

/// 导入页（M2）：选择游戏 Zip → 自动解压到 Documents/games/。
/// 自动定位含 Game.ini 的游戏根，兼容直铺/单层文件夹两种打包。
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  static const _primary = Color(0xFF4CC2FF);
  static const _card = Color(0xFF16161C);

  bool _importing = false;
  bool _keepSave = true;
  String _status = '';
  double _progress = 0;
  String _currentFile = '';

  Future<void> _pick() async {
    setState(() {
      _importing = true;
      _progress = 0;
      _currentFile = '';
      _status = '正在解压…（大游戏请耐心等待）';
    });
    try {
      final name = await GameLibrary.importZip(
        onProgress: (p, file) {
        if (!mounted) return;
        setState(() {
          _progress = p;
          _currentFile = file;
        });
      },
        keepSave: _keepSave,
      );
      if (!mounted) return;
      setState(() => _status = name.isEmpty ? '已取消导入' : '导入完成：$name');
      if (name.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('导入游戏',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Text(
                  '选择一个 RPG Maker XP 游戏的 .zip 压缩包\n\n'
                  '• 自动识别含 Game.ini 的游戏根目录\n'
                  '• 兼容整包直铺与单层文件夹两种打包\n'
                  '• 自动跳过 __MACOSX / .DS_Store 等垃圾文件',
                  style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.8),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('重新导入时保留存档',
                              style: TextStyle(color: Colors.white, fontSize: 14)),
                          SizedBox(height: 2),
                          Text('覆盖同名游戏时保留 Save/ 进度；关闭则干净重导',
                              style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
                    Switch(
                      value: _keepSave,
                      activeColor: _primary,
                      onChanged: _importing
                          ? null
                          : (v) => setState(() => _keepSave = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _importing ? null : _pick,
                icon: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.folder_zip_outlined),
                label: Text(_importing ? '解压中…' : '选择游戏 Zip'),
              ),
              const SizedBox(height: 20),
              if (_importing) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _progress <= 0 ? null : _progress,
                    minHeight: 8,
                    backgroundColor: const Color(0xFF26262E),
                    valueColor: const AlwaysStoppedAnimation(_primary),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${(_progress * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                            color: _primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(_currentFile,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              if (_status.isNotEmpty)
                Text(_status,
                    style: TextStyle(
                        color: _status.startsWith('导入失败')
                            ? const Color(0xFFFF453A)
                            : const Color(0xFF34C759),
                        fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
