import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'main.dart';
import 'theme.dart';

/// Bottom bar on phones, side menu on laptops. Also pops up live notifications.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final StreamSubscription<void> _sub;

  static const _classes = ('/', 'Classes', Icons.videocam_outlined, Icons.videocam_rounded);
  static const _assignments = ('/assignments', 'Assignments', Icons.assignment_outlined, Icons.assignment_rounded);
  static const _students = ('/students', 'Students', Icons.groups_outlined, Icons.groups_rounded);
  static const _alerts = ('/notifications', 'Alerts', Icons.notifications_none_rounded, Icons.notifications_rounded);
  static const _profile = ('/profile', 'Profile', Icons.person_outline_rounded, Icons.person_rounded);

  /// Graduates enrol learners; teachers and learners do the classwork.
  List<(String, String, IconData, IconData)> get _tabs =>
      auth.user?.isGraduate == true ? const [_students, _alerts, _profile] : const [_classes, _assignments, _alerts, _profile];

  @override
  void initState() {
    super.initState();
    _sub = live.incoming.listen((n) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          content: Row(children: [
            const Icon(Icons.notifications_active_rounded, color: Colors.white, size: 26),
            const SizedBox(width: S.md),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(n.title, style: const TextStyle(fontFamily: 'Inter', fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
                if (n.body.isNotEmpty) Text(n.body, style: const TextStyle(fontFamily: 'Inter', fontSize: 16, color: Colors.white70)),
              ]),
            ),
          ]),
          action: SnackBarAction(
            label: 'VIEW',
            textColor: const Color(0xFFFF8FA3),
            onPressed: () {
              live.markRead(n);
              context.push(n.link);
            },
          ),
        ));
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  int get _index {
    final i = _tabs.indexWhere((t) => t.$1 != '/' && widget.location.startsWith(t.$1));
    return i < 0 ? 0 : i;
  }

  Widget _icon(int i, bool selected) {
    final t = _tabs[i];
    final icon = Icon(selected ? t.$4 : t.$3, size: 30);
    return t.$1 == '/notifications'
        ? ListenableBuilder(
            listenable: live,
            builder: (_, _) => Badge(
              isLabelVisible: live.unread > 0,
              label: Text('${live.unread}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              backgroundColor: C.primary,
              child: icon,
            ),
          )
        : icon;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    void go(int i) => context.go(_tabs[i].$1);
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: go,
            extended: MediaQuery.sizeOf(context).width >= 1200,
            minExtendedWidth: 240,
            backgroundColor: C.canvas,
            indicatorColor: C.primary.withValues(alpha: .12),
            selectedIconTheme: const IconThemeData(color: C.primary),
            selectedLabelTextStyle: const TextStyle(fontFamily: 'Inter', fontSize: 18, fontWeight: FontWeight.w700, color: C.primary),
            unselectedLabelTextStyle: const TextStyle(fontFamily: 'Inter', fontSize: 18, fontWeight: FontWeight.w500, color: C.ink),
            labelType: MediaQuery.sizeOf(context).width >= 1200 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: S.lg),
              child: CircleAvatar(radius: 26, backgroundColor: C.primary, child: Icon(Icons.school_rounded, color: Colors.white, size: 28)),
            ),
            destinations: [
              for (var i = 0; i < _tabs.length; i++)
                NavigationRailDestination(
                  icon: _icon(i, false),
                  selectedIcon: _icon(i, true),
                  label: Text(_tabs[i].$2),
                  padding: const EdgeInsets.symmetric(vertical: S.xs),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: widget.child),
        ]),
      );
    }
    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: go,
        height: 84,
        backgroundColor: C.canvas,
        surfaceTintColor: Colors.transparent,
        indicatorColor: C.primary.withValues(alpha: .12),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
              color: s.contains(WidgetState.selected) ? C.primary : C.ink,
            )),
        destinations: [
          for (var i = 0; i < _tabs.length; i++)
            NavigationDestination(icon: _icon(i, false), selectedIcon: _icon(i, true), label: _tabs[i].$2),
        ],
      ),
    );
  }
}
