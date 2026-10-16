import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_settings.dart';
import '../services/game_library.dart';
import '../services/mkxp.dart' show GameEntry;
import 'game_run.dart';

/// 游戏详情页（M2）：点库页列表进入这里，点「开始游戏」才真正启动。
/// 大图横幅 + 标题/引擎徽章 + 开始游戏 + 路径/导入时间/大小 + 快速操作 + 游戏统计。
class GameDetailPage extends StatefulWidget {
  final GameInfo game;
  const GameDetailPage({super.key, required this.game});

  @override
  State<GameDetailPage> createState() => _GameDetailPageState();
}

class _GameDetailPageState extends State<GameDetailPage> {
  static const _primary = Color(0xFF4CC2FF);
  static const _card = Color(0xFF16161C);

  late GameInfo _game;
  bool _starred = false;
  Future<int>? _sizeFuture;
  DateTime? _importedAt;

  @override
  void initState() {
    super.initState();
    _game = widget.game;
    _sizeFuture = _dirSize(Directory(_game.dirPath));
    Directory(_game.dirPath).stat().then((s) {
      if (!mounted) return;
      setState(() => _importedAt = s.changed);
    });
  }

  static Future<int> _dirSize(Directory dir) async {
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += (await e.length());
        } catch (_) {}
      }
    }
    return total;
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime t) =>
      '${t.year} 年 ${t.month} 月 ${t.day} 日 '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _game.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card,
        title: const Text('重命名', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: '新名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('确定', style: TextStyle(color: _primary))),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == _game.name) return;
    try {
      await GameLibrary.rename(_game.name, newName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已重命名为 $newName'), behavior: SnackBarBehavior.floating));
      Navigator.pop(context); // 回库（库页会刷新）
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重命名失败：$e'), behavior: SnackBarBehavior.floating));
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = _game;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            Transform.translate(
              offset: const Offset(0, -26),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 24, 18, 28),
                decoration: const BoxDecoration(
                  color: Color(0xFF0B0B0F),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(g.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    _badges(),
                    const SizedBox(height: 18),
                    _startButton(),
                    const SizedBox(height: 20),
                    _infoCard(),
                    const SizedBox(height: 22),
                    const Text('快速操作',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    _quickActions(),
                    const SizedBox(height: 22),
                    const Text('游戏统计',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    _statsCard(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 顶部大图横幅 + 返回/收藏 ----
  Widget _header() {
    final g = _game;
    return SizedBox(
      height: 280,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (g.iconPath != null)
            Image.file(File(g.iconPath!),
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                errorBuilder: (_, __, ___) => _headerFallback())
          else
            _headerFallback(),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xF00B0B0F), Colors.transparent],
                stops: [0.0, 0.55],
              ),
            ),
          ),
          SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(20),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.arrow_back_ios_new,
                          color: _primary, size: 18),
                      SizedBox(width: 2),
                      Text('我的游戏',
                          style: TextStyle(
                              color: _primary,
                              fontSize: 16,
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(
                      _starred ? Icons.star : Icons.star_border,
                      color: _starred ? const Color(0xFFFFD60A) : Colors.white70),
                  onPressed: () => setState(() => _starred = !_starred),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerFallback() => Container(
        color: const Color(0xFF16161C),
        alignment: Alignment.center,
        child: Text(
          _game.name.isEmpty ? '?' : _game.name.characters.first.toUpperCase(),
          style: TextStyle(
              color: _primary.withValues(alpha: 0.5),
              fontSize: 72,
              fontWeight: FontWeight.w800),
        ),
      );

  // ---- 徽章行：引擎 + 运行时 + 更换图标 ----
  Widget _badges() {
    Widget pill(Widget child, {Color? border, Color? fg}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFF1D1D24),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border ?? Colors.white12),
          ),
          child: child,
        );
    return Row(
      children: [
        pill(const Row(children: [
          Icon(Icons.sports_esports, size: 14, color: Colors.white70),
          SizedBox(width: 5),
          Text('RPG Maker XP',
              style: TextStyle(color: Colors.white70, fontSize: 12)),
        ])),
        const SizedBox(width: 8),
        pill(const Row(children: [
          Icon(Icons.info_outline, size: 14, color: Color(0xFFFFD60A)),
          SizedBox(width: 5),
          Text('运行时', style: TextStyle(color: Color(0xFFFFD60A), fontSize: 12)),
        ]), border: const Color(0x55FFD60A)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.photo_camera_outlined,
              color: Colors.white38, size: 22),
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('自定义图标：即将推出'),
                  behavior: SnackBarBehavior.floating)),
        ),
      ],
    );
  }

  // ---- 开始游戏 ----
  Widget _startButton() => SizedBox(
        height: 52,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => GameRunPage(
                    game: GameEntry(id: _game.name, name: _game.name))));
            if (mounted) setState(() {}); // 返回后刷新统计
          },
          icon: const Icon(Icons.play_circle_fill, size: 26),
          label: const Text('开始游戏',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ),
      );

  // ---- 信息卡：路径/导入时间/大小 ----
  Widget _infoCard() => _cardWrap([
        _infoRow(Icons.folder_outlined, '路径', 'games/${_game.name}'),
        _divider(),
        _infoRow(Icons.calendar_today_outlined, '导入时间',
            _importedAt == null ? '…' : _formatDate(_importedAt!)),
        _divider(),
        _infoRow(Icons.sim_card_download_outlined, '大小', null,
            valueFuture: _sizeFuture?.then(_formatSize)),
      ]);

  // ---- 快速操作：复制 / 重命名 / 报告问题 ----
  Widget _quickActions() => Row(
        children: [
          _actionBtn(Icons.content_copy_outlined, '复制', () async {
            await Clipboard.setData(ClipboardData(text: _game.dirPath));
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('路径已复制'),
                behavior: SnackBarBehavior.floating));
          }),
          const SizedBox(width: 10),
          _actionBtn(Icons.edit_outlined, '重命名', _rename),
          const SizedBox(width: 10),
          _actionBtn(Icons.bug_report_outlined, '报告问题', () {
            Navigator.pushNamed(context, '/log');
          }),
        ],
      );

  // ---- 游戏统计 ----
  Widget _statsCard() {
    return FutureBuilder<(int, int, DateTime?)>(
      future: _stats(),
      builder: (_, snap) {
        final playtime = snap.data?.$1 ?? 0;
        final count = snap.data?.$2 ?? 0;
        final last = snap.data?.$3;
        return _cardWrap([
          _infoRow(Icons.schedule_outlined, '总时长', null,
              valueText: playtime == 0
                  ? '尚未游玩'
                  : AppSettings.formatPlaytime(playtime)),
          _divider(),
          _infoRow(Icons.emoji_events_outlined, '游玩次数', null,
              valueText: '$count 次'),
          _divider(),
          _infoRow(Icons.history_outlined, '最近游玩', null,
              valueText: last == null ? '尚未游玩' : _formatDate(last)),
        ]);
      },
    );
  }

  Future<(int, int, DateTime?)> _stats() async => (
        await AppSettings.playtime(_game.name),
        await AppSettings.playCount(_game.name),
        await AppSettings.lastPlayed(_game.name),
      );

  // ---- 小组件 ----
  Widget _cardWrap(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(children: children),
      );

  Widget _divider() => const Divider(height: 1, color: Colors.white10);

  Widget _infoRow(IconData icon, String label, String? value,
      {String? valueText, Future<String>? valueFuture}) {
    final right = valueFuture != null
        ? FutureBuilder<String>(
            future: valueFuture,
            builder: (_, s) => Text(s.data ?? '计算中…',
                style: const TextStyle(color: Colors.white70, fontSize: 14)))
        : Text(valueText ?? value ?? '',
            style: const TextStyle(color: Colors.white70, fontSize: 14));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: _primary, size: 20),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
          const Spacer(),
          Flexible(child: right),
        ],
      ),
    );
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            children: [
              Icon(icon, color: _primary, size: 22),
              const SizedBox(height: 6),
              Text(label,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
