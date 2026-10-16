import 'dart:io';

import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/game_library.dart';
import 'game_detail.dart';

/// 游戏库页（M2）——「我的游戏」：
/// 搜索栏 + 排序/筛选行 + 游戏列表（圆形图标/名称/引擎副标题/最近游玩）。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const _primary = Color(0xFF4CC2FF);
  static const _card = Color(0xFF16161C);

  List<GameInfo> _games = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final games = await GameLibrary.scan();
    // 排序：最近游玩优先，其次按名称
    final lastPlayed = <String, DateTime>{};
    for (final g in games) {
      final t = await AppSettings.lastPlayed(g.name);
      if (t != null) lastPlayed[g.name] = t;
    }
    games.sort((a, b) {
      final ta = lastPlayed[a.name]?.millisecondsSinceEpoch ?? 0;
      final tb = lastPlayed[b.name]?.millisecondsSinceEpoch ?? 0;
      if (ta != tb) return tb - ta;
      return a.name.compareTo(b.name);
    });
    if (!mounted) return;
    setState(() {
      _games = games;
      _loading = false;
    });
  }

  Future<void> _openImport() async {
    final ok = await Navigator.pushNamed(context, '/import');
    if (ok == true) _refresh();
  }

  Future<void> _delete(GameInfo g) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _card,
        title: const Text('删除游戏', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text('确定删除「${g.name}」？该操作不可恢复。',
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除',
                  style: TextStyle(color: Color(0xFFFF453A)))),
        ],
      ),
    );
    if (yes != true) return;
    await GameLibrary.delete(g.name);
    await _refresh();
  }

  Future<(int, DateTime?)> _meta(GameInfo g) async => (
        await AppSettings.playtime(g.name),
        await AppSettings.lastPlayed(g.name),
      );

  String _formatLastPlayed(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚游玩';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 7) return '${d.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _games
        : _games.where((g) => g.name.toLowerCase().contains(_query)).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('我的游戏',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _importButton(),
                ],
              ),
              const SizedBox(height: 14),
              _searchBar(),
              const SizedBox(height: 10),
              _filterRow(filtered.length),
              const SizedBox(height: 6),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _primary))
                    : filtered.isEmpty
                        ? _emptyView()
                        : RefreshIndicator(
                            color: _primary,
                            onRefresh: _refresh,
                            child: ListView.separated(
                              padding: const EdgeInsets.only(top: 4, bottom: 16),
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, color: Colors.white10),
                              itemBuilder: (_, i) =>
                                  _gameTile(filtered[i]),
                            ),
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _importButton() => InkWell(
        onTap: _openImport,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
              color: _primary, shape: BoxShape.circle),
          child: const Icon(Icons.add, color: Colors.black, size: 26),
        ),
      );

  Widget _searchBar() => Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(Icons.search, color: Colors.white38, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '搜索游戏',
                  hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _filterRow(int count) => SizedBox(
        height: 36,
        child: Row(
          children: [
            const Icon(Icons.filter_list, color: Colors.white38, size: 20),
            const SizedBox(width: 10),
            const Icon(Icons.swap_vert, color: Colors.white38, size: 20),
            const SizedBox(width: 8),
            const Text('最近游玩',
                style: TextStyle(color: Colors.white54, fontSize: 13)),
            const Spacer(),
            Text('$count 个游戏',
                style: const TextStyle(color: Colors.white38, fontSize: 13)),
          ],
        ),
      );

  Widget _emptyView() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sports_esports_outlined,
                size: 56, color: Colors.white.withValues(alpha: 0.15)),
            const SizedBox(height: 12),
            const Text('还没有游戏\n\n点右上角「+」导入游戏 Zip\n或用 iTunes 文件共享把游戏文件夹放进 Documents/',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.6)),
          ],
        ),
      );

  Widget _gameTile(GameInfo g) => InkWell(
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => GameDetailPage(game: g)));
          _refresh();
        },
        onLongPress: () => _delete(g),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              _gameIcon(g),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    const Text('RPG Maker XP',
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FutureBuilder<(int, DateTime?)>(
                future: _meta(g),
                builder: (_, snap) {
                  final playtime = snap.data?.$1 ?? 0;
                  final t = snap.data?.$2;
                  if (playtime == 0 && t == null) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (playtime > 0)
                        Text(AppSettings.formatPlaytime(playtime),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11)),
                      if (t != null) ...[
                        const SizedBox(height: 2),
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.schedule,
                              color: Colors.white24, size: 12),
                          const SizedBox(width: 3),
                          Text(_formatLastPlayed(t),
                              style: const TextStyle(
                                  color: Colors.white24, fontSize: 10)),
                        ]),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: Colors.white24),
            ],
          ),
        ),
      );

  Widget _gameIcon(GameInfo g) {
    final fallback = Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [_primary.withValues(alpha: 0.85), const Color(0xFF5E5CE6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          g.name.isEmpty ? '?' : g.name.characters.first.toUpperCase(),
          style: const TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
    );
    final icon = g.iconPath;
    if (icon == null) return fallback;
    return ClipOval(
      child: SizedBox(
        width: 46,
        height: 46,
        child: Image.file(
          File(icon),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}
