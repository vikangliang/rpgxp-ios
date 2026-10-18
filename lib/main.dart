import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/import.dart';
import 'screens/library.dart';
import 'screens/log_view.dart';
import 'screens/settings.dart';

void main() {
  // 菜单/库/设置页锁竖屏；游戏运行页由原生 setOrientation 单独把 SDL 窗口切横屏。
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const RpgxpLoaderApp());
}

class RpgxpLoaderApp extends StatelessWidget {
  const RpgxpLoaderApp({super.key});

  static const _primary = Color(0xFF4CC2FF);
  static const _bg = Color(0xFF0B0B0F);
  static const _card = Color(0xFF16161C);

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'RPG XP Loader',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: base.colorScheme.copyWith(
          primary: _primary,
          secondary: const Color(0xFF5E5CE6),
          surface: _card,
          error: const Color(0xFFFF453A),
        ),
        appBarTheme: const AppBarTheme(surfaceTintColor: Colors.transparent),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: _card,
          indicatorColor: _primary.withValues(alpha: 0.18),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
              color: s.contains(WidgetState.selected)
                  ? _primary
                  : Colors.white54)),
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 12,
              fontWeight: s.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w400,
              color:
                  s.contains(WidgetState.selected) ? _primary : Colors.white54)),
        ),
      ),
      home: const RootShell(),
      routes: {
        '/import': (_) => const ImportPage(),
        '/log': (_) => const LogPage(),
      },
    );
  }
}

/// 底部双 Tab（游戏 / 设置）。菜单页竖屏（Info.plist 全局锁竖屏，
/// 游戏运行页运行时由原生 setOrientation 切横屏）。
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [LibraryPage(), SettingsPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.sports_esports_outlined),
              selectedIcon: Icon(Icons.sports_esports),
              label: '游戏'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }
}
