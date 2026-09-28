import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../api.dart';
import '../main.dart';
import '../theme.dart';
import '../widgets.dart';

class ChatMessage {
  ChatMessage(this.name, this.text, {this.mine = false});
  final String name, text;
  final bool mine;
}

/// Owns the LiveKit room. Everything live (chat, hands, mute/remove) goes
/// straight through LiveKit — no backend round-trips once the class starts.
class Classroom extends ChangeNotifier {
  Classroom(this.sessionId);
  final String sessionId;

  final room = Room(roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true));
  late final EventsListener<RoomEvent> _events = room.createListener();
  JoinInfo? _join;
  ClassSession? session;
  final messages = <ChatMessage>[];
  int unread = 0;
  bool chatOpen = false;
  String? error;
  String? endedReason;

  bool get connected => room.connectionState == ConnectionState.connected;
  bool get isTeacher => auth.user!.isTeacher;
  LocalParticipant? get me => room.localParticipant;
  bool get handRaised => me?.attributes['hand'] == '1';

  Future<void> start() async {
    try {
      final api = auth.api;
      session = await api.session(sessionId);
      _join = await api.join(sessionId);
      room.addListener(notifyListeners);
      _events
        ..on<DataReceivedEvent>(_onData)
        ..on<RoomDisconnectedEvent>((e) {
          endedReason = switch (e.reason) {
            DisconnectReason.participantRemoved => 'The teacher removed you from this class.',
            DisconnectReason.roomDeleted => 'The class has ended.',
            DisconnectReason.duplicateIdentity => 'You joined this class on another device.',
            DisconnectReason.clientInitiated => null,
            _ => 'You were disconnected.',
          };
          notifyListeners();
        });
      await room.connect(_join!.url, _join!.token);
      // Teachers arrive live; learners arrive muted with camera off.
      if (isTeacher) {
        await _safely(() => me!.setMicrophoneEnabled(true));
        await _safely(() => me!.setCameraEnabled(true));
      }
    } catch (e) {
      error = e is ApiException ? e.message : 'Couldn\'t connect to the class. Check your connection and try again.';
    }
    notifyListeners();
  }

  Future<void> _safely(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {
      error = 'Camera or microphone blocked. Allow access in your browser or phone settings.';
      notifyListeners();
      Future.delayed(const Duration(seconds: 5), () {
        error = null;
        notifyListeners();
      });
    }
  }

  Future<void> toggleMic() => _safely(() => me!.setMicrophoneEnabled(!me!.isMicrophoneEnabled()));
  Future<void> toggleCamera() => _safely(() => me!.setCameraEnabled(!me!.isCameraEnabled()));
  Future<void> toggleScreen() => _safely(() => me!.setScreenShareEnabled(!me!.isScreenShareEnabled()));
  Future<void> toggleHand() => me!.setAttributes({...me!.attributes, 'hand': handRaised ? '' : '1'});

  void _onData(DataReceivedEvent e) {
    final Map<String, dynamic> j;
    try {
      j = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (e.topic == 'chat') {
      messages.add(ChatMessage(e.participant?.name ?? 'Someone', j['text'] as String? ?? ''));
      if (!chatOpen) unread++;
    } else if (e.topic == 'cmd' && j['cmd'] == 'lower_hand' && handRaised) {
      toggleHand();
    }
    notifyListeners();
  }

  Future<void> sendChat(String text) async {
    if (text.trim().isEmpty) return;
    await me!.publishData(utf8.encode(jsonEncode({'text': text.trim()})), reliable: true, topic: 'chat');
    messages.add(ChatMessage(auth.user!.name, text.trim(), mine: true));
    notifyListeners();
  }

  void setChatOpen(bool open) {
    chatOpen = open;
    if (open) unread = 0;
    notifyListeners();
  }

  // ---- Teacher moderation: the teacher's own token is a room-admin token for
  // this room only, so these call LiveKit's API directly.

  Future<void> lowerHand(Participant p) =>
      me!.publishData(utf8.encode(jsonEncode({'cmd': 'lower_hand'})), reliable: true, topic: 'cmd', destinationIdentities: [p.identity]);

  Future<void> muteMic(Participant p) async {
    final pub = p.getTrackPublicationBySource(TrackSource.microphone);
    if (pub != null) await _admin('MutePublishedTrack', {'identity': p.identity, 'track_sid': pub.sid, 'muted': true});
  }

  Future<void> remove(Participant p) => _admin('RemoveParticipant', {'identity': p.identity});

  Future<void> _admin(String method, Map<String, dynamic> body) async {
    final base = _join!.url.replaceFirst(RegExp('^ws'), 'http');
    await http.post(
      Uri.parse('$base/twirp/livekit.RoomService/$method'),
      headers: {'authorization': 'Bearer ${_join!.token}', 'content-type': 'application/json'},
      body: jsonEncode({'room': room.name, ...body}),
    );
  }

  List<Participant> get participants {
    final all = <Participant>[?me, ...room.remoteParticipants.values];
    int rank(Participant p) => isTeacherP(p)
        ? 0
        : p.attributes['hand'] == '1'
        ? 1
        : 2;
    return all..sort((a, b) => rank(a).compareTo(rank(b)));
  }

  static bool isTeacherP(Participant p) => p.attributes['role'] == 'teacher';
  static String? photoOf(Participant p) => absolute(p.attributes['photo']);

  Future<void> leave() => room.disconnect();

  @override
  void dispose() {
    room.removeListener(notifyListeners);
    _events.dispose();
    room.disconnect().whenComplete(room.dispose);
    super.dispose();
  }
}

class ClassroomScreen extends StatefulWidget {
  const ClassroomScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<ClassroomScreen> createState() => _ClassroomScreenState();
}

class _ClassroomScreenState extends State<ClassroomScreen> {
  late final c = Classroom(widget.sessionId)..start();
  bool _peopleOpen = false;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _exit() => context.canPop() ? context.pop() : context.go('/');

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: C.stage,
    body: SafeArea(
      child: ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          if (c.endedReason != null) return _Message(c.endedReason!, onBack: _exit);
          if (c.error != null && !c.connected) return _Message(c.error!, onBack: _exit);
          if (!c.connected) return const _Message('Joining class…', loading: true);
          final wide = MediaQuery.sizeOf(context).width >= 1000;
          final panel = c.chatOpen
              ? _ChatPanel(c)
              : _peopleOpen
              ? _PeoplePanel(c)
              : null;
          return Column(
            children: [
              _TopBar(c),
              if (!c.room.canPlaybackAudio) _Banner('Tap to turn on class sound', onTap: c.room.startAudio),
              if (c.error != null) _Banner(c.error!),
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _Stage(c)),
                    if (wide && panel != null) SizedBox(width: 400, child: panel),
                  ],
                ),
              ),
              _Controls(
                c,
                peopleOpen: _peopleOpen,
                onChat: () => wide ? _togglePanel(chat: true) : _sheet(_ChatPanel(c), chat: true),
                onPeople: () => wide ? _togglePanel(chat: false) : _sheet(_PeoplePanel(c)),
                onLeave: () async {
                  await c.leave();
                  _exit();
                },
              ),
            ],
          );
        },
      ),
    ),
  );

  void _togglePanel({required bool chat}) => setState(() {
    if (chat) {
      _peopleOpen = false;
      c.setChatOpen(!c.chatOpen);
    } else {
      c.setChatOpen(false);
      _peopleOpen = !_peopleOpen;
    }
  });

  Future<void> _sheet(Widget panel, {bool chat = false}) async {
    if (chat) c.setChatOpen(true);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1C1C1C),
      builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * .75, child: panel),
    );
    if (chat) c.setChatOpen(false);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar(this.c);
  final Classroom c;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(S.lg, S.base, S.lg, S.sm),
    child: Row(
      children: [
        const Pill('LIVE', color: C.primary, textColor: Colors.white, dot: Colors.white),
        const SizedBox(width: S.base),
        Expanded(
          child: Text(
            c.session?.title ?? '',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Icon(Icons.people_alt_rounded, color: Colors.white70, size: 26),
        const SizedBox(width: S.sm),
        Text(
          '${c.participants.length}',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(S.lg, S.sm, S.lg, 0),
    child: Material(
      color: C.primary,
      borderRadius: BorderRadius.circular(R.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(R.sm),
        child: Padding(
          padding: const EdgeInsets.all(S.base),
          child: Row(
            children: [
              Icon(onTap != null ? Icons.volume_up_rounded : Icons.info_rounded, color: Colors.white, size: 26),
              const SizedBox(width: S.md),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Screen share takes the stage when active; otherwise a grid of people.
class _Stage extends StatelessWidget {
  const _Stage(this.c);
  final Classroom c;

  @override
  Widget build(BuildContext context) {
    final people = c.participants;
    final sharer = people.where((p) => p.isScreenShareEnabled()).firstOrNull;
    return Padding(
      padding: const EdgeInsets.all(S.base),
      child: LayoutBuilder(
        builder: (context, box) {
          if (sharer != null) {
            final tall = box.maxHeight > box.maxWidth;
            final strip = [for (final p in people) _Tile(p, compact: true)];
            final share = _Tile(sharer, screen: true);
            return tall
                ? Column(
                    children: [
                      Expanded(child: share),
                      const SizedBox(height: S.md),
                      SizedBox(height: 130, child: _Strip(strip, axis: Axis.horizontal)),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: share),
                      const SizedBox(width: S.md),
                      SizedBox(width: 220, child: _Strip(strip, axis: Axis.vertical)),
                    ],
                  );
          }
          // Pick the column count that gives the biggest 16:9 tiles.
          final n = people.length;
          var best = (cols: 1, w: 0.0);
          for (var cols = 1; cols <= n; cols++) {
            final rows = (n / cols).ceil();
            final w = [
              (box.maxWidth - S.md * (cols - 1)) / cols,
              (box.maxHeight - S.md * (rows - 1)) / rows * 16 / 9,
            ].reduce((a, b) => a < b ? a : b);
            if (w > best.w) best = (cols: cols, w: w);
          }
          return Center(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: S.md,
                runSpacing: S.md,
                alignment: WrapAlignment.center,
                children: [for (final p in people) SizedBox(width: best.w, height: best.w * 9 / 16, child: _Tile(p))],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip(this.tiles, {required this.axis});
  final List<Widget> tiles;
  final Axis axis;

  @override
  Widget build(BuildContext context) => ListView.separated(
    scrollDirection: axis,
    itemCount: tiles.length,
    separatorBuilder: (_, _) => const SizedBox(width: S.sm, height: S.sm),
    itemBuilder: (_, i) => AspectRatio(aspectRatio: 16 / 10, child: tiles[i]),
  );
}

class _Tile extends StatelessWidget {
  const _Tile(this.p, {this.screen = false, this.compact = false});
  final Participant p;
  final bool screen, compact;

  @override
  Widget build(BuildContext context) {
    final pub = p.getTrackPublicationBySource(screen ? TrackSource.screenShareVideo : TrackSource.camera);
    final track = pub?.track;
    final showVideo = track is VideoTrack && !pub!.muted;
    final name = p.name.isEmpty ? p.identity : p.name;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: const Color(0xFF262626),
        borderRadius: BorderRadius.circular(compact ? R.sm : R.md),
        border: Border.all(color: p.isSpeaking && !screen ? C.primary : Colors.transparent, width: 3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showVideo)
            VideoTrackRenderer(track, fit: screen ? VideoViewFit.contain : VideoViewFit.cover)
          else
            Center(
              child: Avatar(
                name: name,
                url: Classroom.photoOf(p),
                radius: compact ? 30 : 64,
                color: Classroom.isTeacherP(p) ? C.primary : const Color(0xFF444444),
              ),
            ),
          Positioned(
            left: S.sm,
            bottom: S.sm,
            right: S.sm,
            child: Row(
              children: [
                Flexible(
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 4 : 6),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(R.full)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!screen && !p.isMicrophoneEnabled()) ...[
                          Icon(Icons.mic_off_rounded, size: compact ? 16 : 20, color: Colors.white),
                          const SizedBox(width: 4),
                        ],
                        Flexible(
                          child: Text(
                            screen ? '$name is presenting' : '$name${Classroom.isTeacherP(p) ? ' · Teacher' : ''}',
                            style: TextStyle(fontSize: compact ? 13 : 16, fontWeight: FontWeight.w600, color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!screen && p.attributes['hand'] == '1')
            Positioned(
              right: S.sm,
              top: S.sm,
              child: Container(
                padding: EdgeInsets.all(compact ? 4 : 8),
                decoration: const BoxDecoration(color: Color(0xFFFFC53D), shape: BoxShape.circle),
                child: Icon(Icons.back_hand_rounded, size: compact ? 16 : 26, color: C.ink),
              ),
            ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls(this.c, {required this.peopleOpen, required this.onChat, required this.onPeople, required this.onLeave});
  final Classroom c;
  final bool peopleOpen;
  final VoidCallback onChat, onPeople, onLeave;

  @override
  Widget build(BuildContext context) {
    final me = c.me!;
    final hands = c.participants.where((p) => p.attributes['hand'] == '1').length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.base, S.sm, S.base, S.base),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: S.md,
        runSpacing: S.md,
        children: [
          _RoundButton(
            icon: me.isMicrophoneEnabled() ? Icons.mic_rounded : Icons.mic_off_rounded,
            label: 'Mic',
            off: !me.isMicrophoneEnabled(),
            onTap: c.toggleMic,
          ),
          _RoundButton(
            icon: me.isCameraEnabled() ? Icons.videocam_rounded : Icons.videocam_off_rounded,
            label: 'Camera',
            off: !me.isCameraEnabled(),
            onTap: c.toggleCamera,
          ),
          // Screen share: teachers on the web (Android needs a foreground service — later).
          if (c.isTeacher && kIsWeb)
            _RoundButton(
              icon: Icons.present_to_all_rounded,
              label: me.isScreenShareEnabled() ? 'Stop' : 'Share',
              active: me.isScreenShareEnabled(),
              onTap: c.toggleScreen,
            ),
          if (!c.isTeacher)
            _RoundButton(icon: Icons.back_hand_rounded, label: c.handRaised ? 'Lower' : 'Hand', active: c.handRaised, onTap: c.toggleHand),
          _RoundButton(icon: Icons.chat_bubble_rounded, label: 'Chat', active: c.chatOpen, badge: c.unread, onTap: onChat),
          _RoundButton(
            icon: Icons.people_alt_rounded,
            label: 'People',
            active: peopleOpen,
            badge: c.isTeacher ? hands : 0,
            onTap: onPeople,
          ),
          _RoundButton(icon: Icons.call_end_rounded, label: 'Leave', danger: true, onTap: onLeave),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.off = false,
    this.active = false,
    this.danger = false,
    this.badge = 0,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool off, active, danger;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final bg = danger
        ? C.primary
        : active
        ? Colors.white
        : off
        ? const Color(0xFF5A1F2A)
        : const Color(0xFF333333);
    final fg = active ? C.ink : Colors.white;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Badge(
            isLabelVisible: badge > 0,
            label: Text('$badge', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            backgroundColor: C.primary,
            offset: const Offset(-2, 2),
            child: Material(
              color: bg,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox.square(dimension: 64, child: Icon(icon, size: 30, color: fg)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        ExcludeSemantics(
          child: Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white70),
          ),
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(0, S.base, S.base, S.base),
    decoration: BoxDecoration(color: const Color(0xFF1C1C1C), borderRadius: BorderRadius.circular(R.md)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(S.lg, S.base, S.lg, S.sm),
          child: Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
          ),
        ),
        Expanded(child: child),
      ],
    ),
  );
}

class _ChatPanel extends StatefulWidget {
  const _ChatPanel(this.c);
  final Classroom c;

  @override
  State<_ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<_ChatPanel> {
  final _text = TextEditingController();

  void _send() {
    widget.c.sendChat(_text.text);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'Chat',
    child: ListenableBuilder(
      listenable: widget.c,
      builder: (context, _) {
        final msgs = widget.c.messages.reversed.toList();
        return Column(
          children: [
            Expanded(
              child: msgs.isEmpty
                  ? const Center(
                      child: Text('No messages yet', style: TextStyle(fontSize: 17, color: Colors.white54)),
                    )
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: S.lg),
                      itemCount: msgs.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: S.base),
                        child: Column(
                          crossAxisAlignment: msgs[i].mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          children: [
                            Text(msgs[i].mine ? 'You' : msgs[i].name, style: const TextStyle(fontSize: 14, color: Colors.white54)),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              decoration: BoxDecoration(
                                color: msgs[i].mine ? C.primary : const Color(0xFF333333),
                                borderRadius: BorderRadius.circular(R.md),
                              ),
                              child: Text(msgs[i].text, style: const TextStyle(fontSize: 17, color: Colors.white, height: 1.35)),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(S.base, S.sm, S.base, S.base + MediaQuery.viewInsetsOf(context).bottom),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      onSubmitted: (_) => _send(),
                      style: const TextStyle(fontSize: 18, color: Colors.white),
                      cursorColor: Colors.white,
                      decoration: InputDecoration(
                        hintText: 'Message the class',
                        hintStyle: const TextStyle(fontSize: 17, color: Colors.white38),
                        filled: true,
                        fillColor: const Color(0xFF2A2A2A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(R.full), borderSide: BorderSide.none),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.full), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.full), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: S.sm),
                  IconButton.filled(
                    onPressed: _send,
                    style: IconButton.styleFrom(backgroundColor: C.primary, fixedSize: const Size(56, 56)),
                    icon: const Icon(Icons.send_rounded, color: Colors.white, size: 26),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _PeoplePanel extends StatelessWidget {
  const _PeoplePanel(this.c);
  final Classroom c;

  @override
  Widget build(BuildContext context) => _Panel(
    title: 'People',
    child: ListenableBuilder(
      listenable: c,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: S.base),
        children: [
          for (final p in c.participants)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: S.sm, vertical: 2),
              leading: Avatar(
                name: p.name,
                url: Classroom.photoOf(p),
                radius: 26,
                color: Classroom.isTeacherP(p) ? C.primary : const Color(0xFF444444),
              ),
              title: Text(
                '${p.name}${p is LocalParticipant ? ' (you)' : ''}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (Classroom.isTeacherP(p)) 'Teacher',
                  if (p.attributes['hand'] == '1') 'Hand raised',
                  p.isMicrophoneEnabled() ? 'Mic on' : 'Muted',
                ].join(' · '),
                style: const TextStyle(fontSize: 15, color: Colors.white54),
              ),
              trailing: c.isTeacher && p is RemoteParticipant
                  ? PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 28),
                      onSelected: (a) => switch (a) {
                        'hand' => c.lowerHand(p),
                        'mute' => c.muteMic(p),
                        _ => c.remove(p),
                      },
                      itemBuilder: (_) => [
                        if (p.attributes['hand'] == '1') const PopupMenuItem(value: 'hand', child: Text('Lower hand')),
                        if (p.isMicrophoneEnabled()) const PopupMenuItem(value: 'mute', child: Text('Mute mic')),
                        const PopupMenuItem(value: 'remove', child: Text('Remove from class')),
                      ],
                    )
                  : null,
            ),
        ],
      ),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onBack, this.loading = false});
  final String text;
  final VoidCallback? onBack;
  final bool loading;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(S.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (loading) const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: S.lg),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          if (onBack != null) ...[const SizedBox(height: S.lg), FilledButton(onPressed: onBack, child: const Text('Back to timetable'))],
        ],
      ),
    ),
  );
}
