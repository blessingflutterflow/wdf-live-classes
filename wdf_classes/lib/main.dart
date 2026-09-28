import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'api.dart';
import 'auth.dart';
import 'live.dart';
import 'screens/assignment_screen.dart';
import 'screens/assignments_screen.dart';
import 'screens/classroom_screen.dart' deferred as classroom;
import 'screens/login_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/photo_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/students_screen.dart';
import 'screens/timetable_screen.dart';
import 'shell.dart';
import 'theme.dart';

late final Auth auth;
late final Live live;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  auth = await Auth.load();
  live = Live(auth);
  Api.onUnauthorized = auth.signOut;
  runApp(const App());
}

final _router = GoRouter(
  refreshListenable: auth,
  redirect: (context, state) {
    final at = state.matchedLocation;
    if (!auth.signedIn) return at == '/login' ? null : '/login';
    if (auth.needsPhoto) return at == '/photo' ? null : '/photo';
    final home = auth.user!.isGraduate ? '/students' : '/';
    if (at == '/login' || at == '/photo') return home;
    return auth.user!.isGraduate && at == '/' ? home : null;
  },
  routes: [
    GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    GoRoute(path: '/photo', builder: (_, _) => const PhotoScreen(required: true)),
    // The classroom (and the whole LiveKit SDK) loads on demand, so the
    // other pages open fast on the web.
    GoRoute(
      path: '/class/:id',
      builder: (_, state) => _Deferred(
        load: classroom.loadLibrary,
        builder: () => classroom.ClassroomScreen(sessionId: state.pathParameters['id']!),
      ),
    ),
    ShellRoute(
      builder: (_, state, child) => AppShell(location: state.matchedLocation, child: child),
      routes: [
        GoRoute(path: '/', pageBuilder: (_, _) => const NoTransitionPage(child: TimetableScreen())),
        GoRoute(
          path: '/assignments',
          pageBuilder: (_, _) => const NoTransitionPage(child: AssignmentsScreen()),
          routes: [GoRoute(path: ':id', builder: (_, s) => AssignmentScreen(id: s.pathParameters['id']!))],
        ),
        GoRoute(path: '/students', pageBuilder: (_, _) => const NoTransitionPage(child: StudentsScreen())),
        GoRoute(path: '/notifications', pageBuilder: (_, _) => const NoTransitionPage(child: NotificationsScreen())),
        GoRoute(path: '/profile', pageBuilder: (_, _) => const NoTransitionPage(child: ProfileScreen())),
      ],
    ),
  ],
);

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'WDF Classes',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        routerConfig: _router,
      );
}

class _Deferred extends StatefulWidget {
  const _Deferred({required this.load, required this.builder});
  final Future<void> Function() load;
  final Widget Function() builder;

  @override
  State<_Deferred> createState() => _DeferredState();
}

class _DeferredState extends State<_Deferred> {
  late final _loaded = widget.load();

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _loaded,
        builder: (_, snap) => snap.connectionState == ConnectionState.done
            ? widget.builder()
            : const Scaffold(backgroundColor: C.stage, body: Center(child: CircularProgressIndicator(color: Colors.white))),
      );
}
