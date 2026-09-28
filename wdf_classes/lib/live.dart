import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'auth.dart';

/// Real-time link to the server while the app is open: notifications arrive
/// instantly, and screens refresh the moment something they show changes.
class Live extends ChangeNotifier {
  Live(this._auth) {
    _auth.addListener(_sync);
    _sync();
  }
  final Auth _auth;

  List<AppNotification> notifications = [];
  int get unread => notifications.where((n) => !n.read).length;

  final _incoming = StreamController<AppNotification>.broadcast();
  final _changes = StreamController<String>.broadcast();

  /// New notifications (for the in-app pop-up).
  Stream<AppNotification> get incoming => _incoming.stream;

  /// Topics that changed: 'sessions', 'assignments'.
  Stream<String> get changes => _changes.stream;

  WebSocketChannel? _ws;
  String? _token;
  Timer? _retry;
  var _backoff = 1;

  void _sync() {
    if (_auth.token == _token) return;
    _close();
    _token = _auth.token;
    notifications = [];
    notifyListeners();
    if (_token != null) _connect();
  }

  void _connect() {
    final token = _token;
    if (token == null) return;
    final uri = Uri.parse('${apiUrl.replaceFirst(RegExp('^http'), 'ws')}/api/classes/ws?token=$token');
    final ws = _ws = WebSocketChannel.connect(uri);
    ws.ready.then((_) {
      _backoff = 1;
      refresh();
      // Anything missed while offline.
      _changes
        ..add('sessions')
        ..add('assignments');
    }, onError: (_) {});
    ws.stream.listen(_onMessage, onDone: () => _reconnect(ws), onError: (_) => _reconnect(ws), cancelOnError: true);
  }

  void _reconnect(WebSocketChannel ws) {
    // Ignore sockets we closed ourselves (sign-out / account switch).
    if (!identical(ws, _ws) || _token == null || _retry?.isActive == true) return;
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(1, 30);
  }

  void _onMessage(dynamic raw) {
    final j = jsonDecode(raw as String) as Map<String, dynamic>;
    final topic = j['topic'] as String?;
    if (j['type'] == 'notification') {
      final n = AppNotification.fromJson(j['notification'] as Map<String, dynamic>);
      notifications.insert(0, n);
      _incoming.add(n);
      notifyListeners();
    }
    if (topic != null) _changes.add(topic);
  }

  Future<void> refresh() async {
    try {
      notifications = await _auth.api.notifications();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> markRead([AppNotification? n]) async {
    for (final x in notifications) {
      if (n == null || x.id == n.id) x.read = true;
    }
    notifyListeners();
    try {
      await _auth.api.markRead(n == null ? null : [n.id]);
    } catch (_) {}
  }

  void _close() {
    _retry?.cancel();
    _ws?.sink.close();
    _ws = null;
  }
}
