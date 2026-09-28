import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../format.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  IconData _icon(String link) => link.startsWith('/assignments')
      ? Icons.assignment_rounded
      : link.startsWith('/class')
          ? Icons.videocam_rounded
          : Icons.event_rounded;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Alerts'),
          titleSpacing: S.lg,
          actions: [
            ListenableBuilder(
              listenable: live,
              builder: (_, _) => live.unread == 0
                  ? const SizedBox()
                  : Padding(
                      padding: const EdgeInsets.only(right: S.base),
                      child: TextButton(onPressed: () => live.markRead(), child: const Text('Mark all read')),
                    ),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: live.refresh,
          color: C.primary,
          child: ListenableBuilder(
            listenable: live,
            builder: (context, _) {
              final list = live.notifications;
              if (list.isEmpty) {
                return ListView(children: const [
                  SizedBox(height: 120),
                  EmptyState(icon: Icons.notifications_none_rounded, text: 'No alerts yet. New assignments, marks and class reminders show up here.'),
                ]);
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: S.sm),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(indent: S.lg, endIndent: S.lg),
                itemBuilder: (_, i) {
                  final n = list[i];
                  return PageWidth(
                    max: 800,
                    child: InkWell(
                      onTap: () {
                        live.markRead(n);
                        context.push(n.link);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: S.lg, vertical: S.base),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          CircleAvatar(
                            radius: 26,
                            backgroundColor: n.read ? C.surfaceStrong : C.primary.withValues(alpha: .12),
                            child: Icon(_icon(n.link), color: n.read ? C.muted : C.primary, size: 28),
                          ),
                          const SizedBox(width: S.base),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(n.title, style: T.cardTitle.copyWith(fontSize: 19, fontWeight: n.read ? FontWeight.w500 : FontWeight.w700)),
                              if (n.body.isNotEmpty) Text(n.body, style: T.body.copyWith(fontSize: 17)),
                              const SizedBox(height: S.xs),
                              Text(ago(n.createdAt), style: T.label.copyWith(fontSize: 15)),
                            ]),
                          ),
                          if (!n.read)
                            Container(
                              margin: const EdgeInsets.only(top: 10, left: S.sm),
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(color: C.primary, shape: BoxShape.circle),
                            ),
                        ]),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      );
}
