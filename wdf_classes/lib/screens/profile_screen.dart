import 'package:flutter/material.dart';

import '../api.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';
import 'photo_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Profile'), titleSpacing: S.lg),
        body: ListenableBuilder(
          listenable: auth,
          builder: (context, _) {
            final u = auth.user;
            if (u == null) return const SizedBox();
            return ListView(padding: const EdgeInsets.all(S.lg), children: [
              PageWidth(
                max: 640,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(child: Avatar(name: u.name, url: u.photoUrl, radius: 80, color: u.isTeacher ? C.primary : C.ink)),
                  const SizedBox(height: S.lg),
                  Text(u.name, style: T.display, textAlign: TextAlign.center),
                  const SizedBox(height: S.xs),
                  Text(u.roleLabel, style: T.body, textAlign: TextAlign.center),
                  const SizedBox(height: S.xl),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhotoScreen())),
                    icon: const Icon(Icons.photo_camera_rounded, size: 26),
                    label: Text(u.photo == null ? 'Add photo' : 'Change photo'),
                  ),
                  const SizedBox(height: S.xl),
                  const Text('My subjects', style: T.title),
                  const SizedBox(height: S.base),
                  FutureBuilder<List<Subject>>(
                    future: auth.api.subjects(),
                    builder: (_, snap) => Column(children: [
                      for (final s in snap.data ?? <Subject>[])
                        Container(
                          margin: const EdgeInsets.only(bottom: S.md),
                          padding: const EdgeInsets.all(S.base),
                          decoration: BoxDecoration(border: Border.all(color: C.hairline), borderRadius: BorderRadius.circular(R.md)),
                          child: Row(children: [
                            const Icon(Icons.menu_book_rounded, size: 30, color: C.primary),
                            const SizedBox(width: S.md),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(s.name, style: T.cardTitle),
                                Text(u.isTeacher ? '${s.learnerCount} learners' : s.teacherName, style: T.meta),
                              ]),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                  const SizedBox(height: S.xl),
                  FilledButton(onPressed: auth.signOut, style: FilledButton.styleFrom(backgroundColor: C.ink), child: const Text('Sign out')),
                ]),
              ),
            ]);
          },
        ),
      );
}
