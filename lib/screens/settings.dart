import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/mkxp.dart';

/// 设置页（M2）：iOS 风格分组卡片。
/// 「通用」组：语言 / 外观（占位）。
/// 「游戏」组：常亮 / 固定横屏 / 控制器振动（即时生效）+ 三个后续项占位。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _keepAwake = true;
  bool _lockLandscape = true;
  bool _vibration = true;

  static const _primary = Color(0xFF4CC2FF);
  static const _card = Color(0xFF16161C);

  @override
  void initState() {
    super.initState();
    AppSettings.load().then((s) {
      if (!mounted) return;
      setState(() {
        _keepAwake = s.keepAwake;
        _lockLandscape = s.lockLandscape;
        _vibration = s.vibration;
      });
    });
  }

  Future<void> _persist() async {
    await AppSettings.save(
      keepAwake: _keepAwake,
      lockLandscape: _lockLandscape,
      vibration: _vibration,
    );
  }

  void _todo(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$what：即将推出'), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0F),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            const Text('设置',
                style: TextStyle(
                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _group('通用', [
              _row(Icons.language, '语言',
                  trailing: _chevronText('简体中文'),
                  onTap: () => _todo('语言切换')),
              _row(Icons.dark_mode_outlined, '外观',
                  trailing: _chevronText('自动'),
                  onTap: () => _todo('外观切换')),
            ]),
            const SizedBox(height: 16),
            _group('游戏', [
              _row(Icons.wb_sunny_outlined, '保持屏幕常亮',
                  trailing: _switch(_keepAwake, (v) async {
                    setState(() => _keepAwake = v);
                    await _persist();
                    await Mkxp.setKeepAwake(v);
                  })),
              _row(Icons.screen_rotation_outlined, '固定横屏游戏',
                  trailing: _switch(_lockLandscape, (v) async {
                    setState(() => _lockLandscape = v);
                    await _persist();
                  })),
              _row(Icons.vibration_outlined, '控制器振动',
                  trailing: _switch(_vibration, (v) async {
                    setState(() => _vibration = v);
                    await _persist();
                    if (v) await Mkxp.haptic();
                  })),
              _row(Icons.tune, '默认游戏配置', onTap: () => _todo('默认游戏配置')),
              _row(Icons.keyboard_outlined, '虚拟键盘预设', onTap: () => _todo('虚拟键盘预设')),
              _row(Icons.sports_esports_outlined, '实体手柄', onTap: () => _todo('实体手柄')),
            ]),
            const SizedBox(height: 16),
            _group('关于', [
              _row(Icons.article_outlined, '运行日志',
                  trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                  onTap: () => Navigator.pushNamed(context, '/log')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _group(String title, List<Widget> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 6),
            child: Text(title,
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ),
          Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  rows[i],
                  if (i != rows.length - 1)
                    const Divider(height: 1, indent: 52, color: Colors.white10),
                ],
              ],
            ),
          ),
        ],
      );

  Widget _row(IconData icon, String label,
      {Widget? trailing, VoidCallback? onTap}) {
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      leading: Icon(icon, color: _primary, size: 24),
      title: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 15)),
      trailing: trailing,
    );
  }

  Widget _chevronText(String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: const TextStyle(color: Colors.white38, fontSize: 14)),
          const Icon(Icons.chevron_right, color: Colors.white38),
        ],
      );

  Widget _switch(bool value, ValueChanged<bool> onChanged) => Switch(
        value: value,
        onChanged: onChanged,
        activeColor: const Color(0xFF34C759),
      );
}
