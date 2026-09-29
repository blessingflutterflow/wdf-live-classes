import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_background/flutter_background.dart';
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

/// Owns the LiveKit room. Everything live (chat, hands, mute) goes straight through LiveKit.
///
/// Classroom rules (Nosipho, 29 Sep 2026): everyone watches ONE big screen — the teacher, the
/// teacher's screen share, or the learner the teacher has unmuted while they talk. Learners join
/// with mic and camera off and LOCKED (their LiveKit token can't publish); only the teacher can
/// unmute a learner (voice only — learner cameras never come on). Raised hands queue for the teacher.
class Classroom extends ChangeNotifier {
  Classroom(this.sessionId);
  final String sessionId;

  final room = Room(
    roomOptions: const RoomOptions(
      adaptiveStream: true,
      dynacast: true,
      // Screen share: sharp text (1080p, 15 fps) plus a lighter layer for small phone screens.
      defaultVideoPublishOptions: VideoPublishOptions(
        screenShareEncoding: VideoEncoding(maxBitrate: 2500000, maxFramerate: 15),
        screenShareSimulcastLayers: [VideoParametersPresets.screenShareH720FPS5],
      ),
    ),
  );
  late final EventsListener<RoomEvent> _events = room.createListener();
  JoinInfo? _join;
  ClassSession? session;
  final messages = <ChatMessage>[];
  int unread = 0;
  bool chatOpen = false;
  String? error;
  String? endedReason;

  // The learner currently talking (after the teacher unmuted them) takes the big screen.
  String? _speakerId;
  DateTime _speakerUntil = DateTime(0);
  Timer? _speakerTimer;

  bool get connected => room.connectionState == ConnectionState.connected;
  bool get isTeacher => auth.user!.isTeacher;
  LocalParticipant? get me => room.localParticipant;
  bool get handRaised => me?.attributes['hand'] == '1';

  static bool isTeacherP(Participant p) => p.attributes['role'] == 'teacher';
  static String? photoOf(Participant p) => absolute(p.attributes['photo']);

  /// A learner the teacher has unmuted (attribute set by the teacher through LiveKit).
  static bool mayTalk(Participant p) => p.attributes['mic'] == '1';
  static bool handUp(Participant p) => p.attributes['hand'] == '1';

  /// Can *I* use my mic right now?
  bool get canTalk => isTeacher || (me != null && mayTalk(me!));

  List<Participant> get participants => <Participant>[?me, ...room.remoteParticipants.values];
  List<Participant> get learners => participants.where((p) => !isTeacherP(p)).toList();
  List<Participant> get hands => learners.where(handUp).toList();
  List<Participant> get speakers => learners.where(mayTalk).toList();

  /// The teacher on screen: the one sharing, else one with a camera, else any teacher.
  Participant? get teacher {
    final ts = participants.where(isTeacherP).toList();
    return ts.where((p) => p.isScreenShareEnabled()).firstOrNull ??
        ts.where((p) => p.isCameraEnabled()).firstOrNull ??
        ts.firstOrNull;
  }

  Participant? get sharer => participants.where((p) => p.isScreenShareEnabled()).firstOrNull;

  /// The unmuted learner who is talking right now (kept for a few seconds after they pause).
  Participant? get spotlight {
    if (_speakerId == null || DateTime.now().isAfter(_speakerUntil)) return null;
    return participants.where((p) => p.identity == _speakerId && mayTalk(p)).firstOrNull;
  }

  Future<void> start() async {
    try {
      final api = auth.api;
      session = await api.session(sessionId);
      _join = await api.join(sessionId);
      room.addListener(notifyListeners);
      _events
        ..on<DataReceivedEvent>(_onData)
        ..on<ActiveSpeakersChangedEvent>((e) {
          final s = e.speakers.where((p) => !isTeacherP(p) && mayTalk(p)).firstOrNull;
          if (s != null) {
            _speakerId = s.identity;
            _speakerUntil = DateTime.now().add(const Duration(seconds: 4));
            _speakerTimer?.cancel();
            _speakerTimer = Timer(const Duration(milliseconds: 4200), notifyListeners);
          }
          notifyListeners();
        })
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
      // Teachers arrive live; learners arrive with mic and camera off (and can't switch them on).
      if (isTeacher) {
        await _safely(() => me!.setMicrophoneEnabled(true));
        await _safely(() => me!.setCameraEnabled(true));
      }
    } catch (e) {
      error = e is ApiException ? e.message : 'Couldn\'t connect to the class. Check your connection and try again.';
    }
    notifyListeners();
  }

  void _say(String message) {
    error = message;
    notifyListeners();
    Future.delayed(const Duration(seconds: 5), () {
      if (error == message) {
        error = null;
        notifyListeners();
      }
    });
  }

  Future<void> _safely(Future<void> Function() f, [String? failure]) async {
    try {
      await f();
    } catch (_) {
      _say(failure ?? 'Camera or microphone blocked. Allow access in your browser or phone settings.');
    }
  }

  Future<void> toggleMic() async {
    if (!canTalk) return _say('Raise your hand — your teacher will unmute you.');
    await _safely(() => me!.setMicrophoneEnabled(!me!.isMicrophoneEnabled()));
  }

  Future<void> toggleCamera() => _safely(() => me!.setCameraEnabled(!me!.isCameraEnabled()));

  /// Phone browsers can't share their screen at all; the Android app can (it needs a foreground
  /// service while sharing); laptop browsers can.
  static bool get _phoneBrowser =>
      kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  static bool get _androidApp => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> toggleScreen() async {
    final on = me!.isScreenShareEnabled();
    if (!on && _phoneBrowser) {
      return _say('Phone browsers can\'t share the screen. Use the WDF Classes Android app, or a laptop.');
    }
    if (!on && _androidApp) {
      try {
        await FlutterBackground.initialize(
          androidConfig: const FlutterBackgroundAndroidConfig(
            notificationTitle: 'WDF Classes',
            notificationText: 'You are sharing your screen with the class.',
            shouldRequestBatteryOptimizationsOff: false,
          ),
        );
        if (!FlutterBackground.isBackgroundExecutionEnabled) await FlutterBackground.enableBackgroundExecution();
      } catch (_) {
        return _say('Screen sharing needs permission. Please allow it and try again.');
      }
    }
    await _safely(() => me!.setScreenShareEnabled(!on), 'Screen sharing was cancelled or blocked.');
    if (on && _androidApp) {
      try {
        await FlutterBackground.disableBackgroundExecution();
      } catch (_) {}
    }
  }

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
    } else if (e.topic == 'cmd' && j['cmd'] == 'allow_mic') {
      // The teacher unmuted me: switch my mic on (give LiveKit a moment to apply the permission).
      Future.delayed(const Duration(milliseconds: 800), () => _safely(() => me!.setMicrophoneEnabled(true)));
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

  // ---- Teacher controls. The teacher's own token is a room-admin token for this room only, so
  // these call LiveKit's API directly.

  /// Unmute a learner (voice only): allow their mic, lower their hand, switch their mic on.
  Future<void> unmute(Participant p) async {
    await _perms(p, mic: true);
    await me!.publishData(utf8.encode(jsonEncode({'cmd': 'allow_mic'})), reliable: true, topic: 'cmd', destinationIdentities: [p.identity]);
  }

  /// Mute a learner again: their mic is removed and blocked.
  Future<void> mute(Participant p) => _perms(p, mic: false);

  /// Mute every learner who was unmuted.
  Future<void> muteAll() async {
    final talking = speakers;
    for (var i = 0; i < talking.length; i += 25) {
      await Future.wait(talking.skip(i).take(25).map(mute));
    }
  }

  Future<void> lowerHand(Participant p) =>
      me!.publishData(utf8.encode(jsonEncode({'cmd': 'lower_hand'})), reliable: true, topic: 'cmd', destinationIdentities: [p.identity]);

  Future<void> remove(Participant p) => _admin('RemoveParticipant', {'identity': p.identity});

  /// A learner may publish their microphone only while unmuted; never their camera. Without the
  /// permission LiveKit removes the track and refuses to let them switch it on.
  Future<void> _perms(Participant p, {required bool mic}) => _admin('UpdateParticipant', {
        'identity': p.identity,
        'attributes': {'mic': mic ? '1' : '', 'hand': ''},
        'permission': {
          'canSubscribe': true,
          'canPublish': mic,
          'canPublishData': true,
          'canUpdateMetadata': true,
          'canPublishSources': [if (mic) 'MICROPHONE'],
        },
      });

  Future<void> _admin(String method, Map<String, dynamic> body) async {
    final base = _join!.url.replaceFirst(RegExp('^ws'), 'http');
    final res = await http.post(
      Uri.parse('$base/twirp/livekit.RoomService/$method'),
      headers: {'authorization': 'Bearer ${_join!.token}', 'content-type': 'application/json'},
      body: jsonEncode({'room': room.name, ...body}),
    );
    if (res.statusCode >= 300) _say('That didn\'t work — please try again.');
  }

  Future<void> leave() => room.disconnect();

  @override
  void dispose() {
    _speakerTimer?.cancel();
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
  bool _full = false; // screen share full screen: hide everything else

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
              final full = _full && c.sharer != null;
              final panel = c.chatOpen
                  ? _ChatPanel(c)
                  : _peopleOpen && c.isTeacher
                      ? _PeoplePanel(c)
                      : null;
              return Column(children: [
                if (!full) _TopBar(c, onHands: _openPeople),
                if (!c.room.canPlaybackAudio) _Banner('Tap to turn on class sound', onTap: c.room.startAudio),
                if (c.error != null) _Banner(c.error!),
                Expanded(
                  child: Row(children: [
                    Expanded(child: _Stage(c, full: full, onFull: () => setState(() => _full = !_full))),
                    if (wide && panel != null && !full) SizedBox(width: 420, child: panel),
                  ]),
                ),
                if (!full)
                  _Controls(
                    c,
                    peopleOpen: _peopleOpen,
                    onChat: () => wide ? _togglePanel(chat: true) : _sheet(_ChatPanel(c), chat: true),
                    onPeople: _openPeople,
                    onLeave: () async {
                      await c.leave();
                      _exit();
                    },
                  ),
              ]);
            },
          ),
        ),
      );

  void _openPeople() {
    if (!c.isTeacher) return;
    if (MediaQuery.sizeOf(context).width >= 1000) {
      _togglePanel(chat: false);
    } else {
      _sheet(_PeoplePanel(c));
    }
  }

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
      builder: (_) => SizedBox(height: MediaQuery.sizeOf(context).height * .8, child: panel),
    );
    if (chat) c.setChatOpen(false);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar(this.c, {required this.onHands});
  final Classroom c;
  final VoidCallback onHands;

  @override
  Widget build(BuildContext context) {
    final hands = c.hands.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.lg, S.base, S.lg, S.sm),
      child: Row(children: [
        const Pill('LIVE', color: C.primary, textColor: Colors.white, dot: Colors.white),
        const SizedBox(width: S.base),
        Expanded(
          child: Text(c.session?.title ?? '',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        // Teacher: raised hands, right where they can't be missed.
        if (c.isTeacher && hands > 0) ...[
          Semantics(
            button: true,
            label: 'Hands up $hands',
            excludeSemantics: true,
            child: Material(
              color: const Color(0xFFFFC53D),
              borderRadius: BorderRadius.circular(R.full),
              child: InkWell(
                onTap: onHands,
                borderRadius: BorderRadius.circular(R.full),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text('✋ $hands', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: C.ink)),
                ),
              ),
            ),
          ),
          const SizedBox(width: S.md),
        ],
        const Icon(Icons.people_alt_rounded, color: Colors.white70, size: 24),
        const SizedBox(width: S.xs),
        Text('${c.participants.length}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white)),
      ]),
    );
  }
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
              child: Row(children: [
                Icon(onTap != null ? Icons.volume_up_rounded : Icons.info_rounded, color: Colors.white, size: 26),
                const SizedBox(width: S.md),
                Expanded(child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white))),
              ]),
            ),
          ),
        ),
      );
}

/// ONE big screen: the teacher's screen share, else the unmuted learner who is talking, else the
/// teacher. When someone else holds the screen, the teacher stays visible in a small corner view.
class _Stage extends StatelessWidget {
  const _Stage(this.c, {required this.full, required this.onFull});
  final Classroom c;
  final bool full;
  final VoidCallback onFull;

  @override
  Widget build(BuildContext context) {
    final teacher = c.teacher;
    final sharer = c.sharer;
    final spot = c.spotlight;
    final main = sharer ?? spot ?? teacher;
    return Padding(
      padding: EdgeInsets.all(full ? 0 : S.base),
      child: LayoutBuilder(builder: (context, box) {
        if (main == null) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.hourglass_top_rounded, size: 56, color: Colors.white54),
              const SizedBox(height: S.base),
              const Text('Waiting for the teacher to join…',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: S.xs),
              Text('${c.participants.length} in class', style: const TextStyle(fontSize: 17, color: Colors.white54)),
            ]),
          );
        }
        final showPip = teacher != null && (sharer != null || (spot != null && spot != teacher));
        final pipW = math.min(box.maxWidth * .3, 260.0);
        return Stack(children: [
          Positioned.fill(child: sharer != null ? _ShareView(sharer, full: full, onFull: onFull) : _Tile(main)),
          if (showPip && !full)
            Positioned(
              right: S.md,
              bottom: S.md,
              width: pipW,
              height: pipW * 10 / 16,
              child: DecoratedBox(
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(R.sm), boxShadow: const [
                  BoxShadow(color: Colors.black54, blurRadius: 12),
                ]),
                child: _Tile(teacher, compact: true),
              ),
            ),
          // During a screen share, say who is talking (their face isn't on screen).
          if (sharer != null && spot != null && !full)
            Positioned(
              left: S.md,
              bottom: S.md,
              child: Pill('🎤 ${spot.name} is speaking', color: Colors.black87, textColor: Colors.white),
            ),
        ]);
      }),
    );
  }
}

/// A screen share that works on any screen: fitted whole, pinch/scroll to zoom, full-screen button.
class _ShareView extends StatelessWidget {
  const _ShareView(this.p, {required this.full, required this.onFull});
  final Participant p;
  final bool full;
  final VoidCallback onFull;

  @override
  Widget build(BuildContext context) {
    final pub = p.getTrackPublicationBySource(TrackSource.screenShareVideo);
    final track = pub?.track;
    final name = p.name.isEmpty ? p.identity : p.name;
    return ClipRRect(
      borderRadius: BorderRadius.circular(full ? 0 : R.md),
      child: ColoredBox(
        color: Colors.black,
        child: LayoutBuilder(builder: (context, box) {
          final portrait = box.maxHeight > box.maxWidth;
          return Stack(children: [
            if (track is VideoTrack)
              InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: SizedBox(
                  width: box.maxWidth,
                  height: box.maxHeight,
                  child: VideoTrackRenderer(track, fit: VideoViewFit.contain),
                ),
              )
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            Positioned(left: S.md, top: S.md, child: Pill('$name is presenting', color: Colors.black87, textColor: Colors.white)),
            Positioned(
              right: S.sm,
              top: S.sm,
              child: Semantics(
                button: true,
                label: full ? 'Exit full screen' : 'Full screen',
                excludeSemantics: true,
                child: IconButton.filled(
                  onPressed: onFull,
                  style: IconButton.styleFrom(backgroundColor: Colors.black87, fixedSize: const Size(56, 56)),
                  icon: Icon(full ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Colors.white, size: 32),
                ),
              ),
            ),
            if (full && portrait)
              Positioned(
                left: S.lg,
                right: S.lg,
                bottom: S.lg,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(R.md)),
                    child: const Text('Turn your phone sideways for a bigger view.\nPinch to zoom in.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
                ),
              ),
          ]);
        }),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.p, {this.compact = false});
  final Participant p;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final pub = p.getTrackPublicationBySource(TrackSource.camera);
    final track = pub?.track;
    final showVideo = track is VideoTrack && !pub!.muted;
    final name = p.name.isEmpty ? p.identity : p.name;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: const Color(0xFF262626),
        borderRadius: BorderRadius.circular(compact ? R.sm : R.md),
        border: Border.all(color: p.isSpeaking ? C.primary : Colors.transparent, width: 3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        if (showVideo)
          VideoTrackRenderer(track, fit: VideoViewFit.cover)
        else
          Center(
            child: Avatar(
              name: name,
              url: Classroom.photoOf(p),
              radius: compact ? 28 : 72,
              color: Classroom.isTeacherP(p) ? C.primary : const Color(0xFF444444),
            ),
          ),
        Positioned(
          left: S.sm,
          bottom: S.sm,
          right: S.sm,
          child: Row(children: [
            Flexible(
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 4 : 6),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(R.full)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (!p.isMicrophoneEnabled()) ...[
                    Icon(Icons.mic_off_rounded, size: compact ? 16 : 20, color: Colors.white),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      '$name${Classroom.isTeacherP(p) ? ' · Teacher' : ''}',
                      style: TextStyle(fontSize: compact ? 13 : 17, fontWeight: FontWeight.w600, color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              ),
            ),
          ]),
        ),
      ]),
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
    final micOn = me.isMicrophoneEnabled();
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.base, S.sm, S.base, S.base),
      child: Wrap(alignment: WrapAlignment.center, spacing: S.md, runSpacing: S.md, children: [
        _RoundButton(
          // Learners who haven't been unmuted see a padlock; tapping explains how to speak.
          icon: !c.canTalk ? Icons.lock_rounded : micOn ? Icons.mic_rounded : Icons.mic_off_rounded,
          label: !c.canTalk ? 'Muted' : 'Mic',
          off: !micOn,
          onTap: c.toggleMic,
        ),
        if (c.isTeacher) ...[
          _RoundButton(
            icon: me.isCameraEnabled() ? Icons.videocam_rounded : Icons.videocam_off_rounded,
            label: 'Camera',
            off: !me.isCameraEnabled(),
            onTap: c.toggleCamera,
          ),
          _RoundButton(
            icon: Icons.present_to_all_rounded,
            label: me.isScreenShareEnabled() ? 'Stop' : 'Share',
            active: me.isScreenShareEnabled(),
            onTap: c.toggleScreen,
          ),
          if (c.speakers.isNotEmpty) _RoundButton(icon: Icons.mic_off_rounded, label: 'Mute all', onTap: c.muteAll),
        ] else
          _RoundButton(icon: Icons.back_hand_rounded, label: c.handRaised ? 'Lower' : 'Hand', active: c.handRaised, onTap: c.toggleHand),
        _RoundButton(icon: Icons.chat_bubble_rounded, label: 'Chat', active: c.chatOpen, badge: c.unread, onTap: onChat),
        if (c.isTeacher)
          _RoundButton(icon: Icons.people_alt_rounded, label: 'People', active: peopleOpen, badge: c.hands.length, onTap: onPeople),
        _RoundButton(icon: Icons.call_end_rounded, label: 'Leave', danger: true, onTap: onLeave),
      ]),
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
    return Column(mainAxisSize: MainAxisSize.min, children: [
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
        child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white70)),
      ),
    ]);
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
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(S.lg, S.base, S.lg, S.sm),
            child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
          Expanded(child: child),
        ]),
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
            return Column(children: [
              Expanded(
                child: msgs.isEmpty
                    ? const Center(child: Text('No messages yet', style: TextStyle(fontSize: 17, color: Colors.white54)))
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
                child: Row(children: [
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
                ]),
              ),
            ]);
          },
        ),
      );
}

/// Teacher only: raised hands first (big Unmute buttons), then who is unmuted, then everyone.
class _PeoplePanel extends StatefulWidget {
  const _PeoplePanel(this.c);
  final Classroom c;

  @override
  State<_PeoplePanel> createState() => _PeoplePanelState();
}

class _PeoplePanelState extends State<_PeoplePanel> {
  String _q = '';

  @override
  Widget build(BuildContext context) => _Panel(
        title: 'People',
        child: ListenableBuilder(
          listenable: widget.c,
          builder: (context, _) {
            final c = widget.c;
            final hands = c.hands;
            final talking = c.speakers;
            final everyone = [
              ...c.participants.where(Classroom.isTeacherP),
              ...(c.learners..sort((a, b) => a.name.compareTo(b.name))),
            ].where((p) => _q.isEmpty || p.name.toLowerCase().contains(_q)).toList();
            // One flat list so hundreds of people scroll smoothly.
            final items = <Widget>[
              _Section('✋ Hands up', hands.length),
              if (hands.isEmpty) const _Hint('No hands up.'),
              for (final p in hands)
                _PersonRow(p, trailing: [
                  FilledButton(
                    onPressed: () => c.unmute(p),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 18)),
                    child: const Text('Unmute'),
                  ),
                  IconButton(
                    tooltip: 'Lower hand',
                    onPressed: () => c.lowerHand(p),
                    icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  ),
                ]),
              _Section('🎤 Speaking', talking.length),
              if (talking.isEmpty) const _Hint('Everyone is muted.'),
              for (final p in talking)
                _PersonRow(p, trailing: [
                  OutlinedButton(
                    onPressed: () => c.mute(p),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: const Text('Mute'),
                  ),
                ]),
              _Section('Everyone', c.participants.length),
              Padding(
                padding: const EdgeInsets.fromLTRB(S.sm, 0, S.sm, S.sm),
                child: TextField(
                  onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                  style: const TextStyle(fontSize: 17, color: Colors.white),
                  cursorColor: Colors.white,
                  decoration: InputDecoration(
                    hintText: 'Search name',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF2A2A2A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(R.full), borderSide: BorderSide.none),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.full), borderSide: BorderSide.none),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.full), borderSide: BorderSide.none),
                  ),
                ),
              ),
            ];
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(S.base, 0, S.base, S.lg),
              itemCount: items.length + everyone.length,
              itemBuilder: (_, i) {
                if (i < items.length) return items[i];
                final p = everyone[i - items.length];
                final learner = !Classroom.isTeacherP(p) && p is RemoteParticipant;
                return _PersonRow(p, trailing: [
                  if (learner)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 28),
                      onSelected: (a) => switch (a) {
                        'unmute' => c.unmute(p),
                        'mute' => c.mute(p),
                        _ => c.remove(p),
                      },
                      itemBuilder: (_) => [
                        if (!Classroom.mayTalk(p)) const PopupMenuItem(value: 'unmute', child: Text('Unmute')),
                        if (Classroom.mayTalk(p)) const PopupMenuItem(value: 'mute', child: Text('Mute')),
                        const PopupMenuItem(value: 'remove', child: Text('Remove from class')),
                      ],
                    ),
                ]);
              },
            );
          },
        ),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.count);
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(S.sm, S.lg, S.sm, S.sm),
        child: Text('$title ($count)', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
      );
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(S.sm, 0, S.sm, S.sm),
        child: Text(text, style: const TextStyle(fontSize: 15, color: Colors.white38)),
      );
}

class _PersonRow extends StatelessWidget {
  const _PersonRow(this.p, {required this.trailing});
  final Participant p;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final teacher = Classroom.isTeacherP(p);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: S.sm, vertical: 6),
      child: Row(children: [
        Avatar(name: p.name, url: Classroom.photoOf(p), radius: 24, color: teacher ? C.primary : const Color(0xFF444444)),
        const SizedBox(width: S.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p.name}${p is LocalParticipant ? ' (you)' : ''}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white), overflow: TextOverflow.ellipsis),
            Text(
              teacher
                  ? 'Teacher'
                  : Classroom.mayTalk(p)
                      ? 'Unmuted'
                      : 'Muted',
              style: const TextStyle(fontSize: 14, color: Colors.white54),
            ),
          ]),
        ),
        ...trailing,
      ]),
    );
  }
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (loading) const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: S.lg),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white)),
            if (onBack != null) ...[
              const SizedBox(height: S.lg),
              FilledButton(onPressed: onBack, child: const Text('Back to timetable')),
            ],
          ]),
        ),
      );
}
