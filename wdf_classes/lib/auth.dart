import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Signed-in user + API token, remembered across launches.
class Auth extends ChangeNotifier {
  Auth._(this._prefs);
  final SharedPreferences _prefs;

  String? token;
  User? user;

  bool get signedIn => user != null;

  /// Learners must add a profile photo before using the app.
  bool get needsPhoto => user != null && user!.isLearner && user!.photo == null;
  Api get api => Api(token);

  static Future<Auth> load() async {
    final auth = Auth._(await SharedPreferences.getInstance());
    auth.token = auth._prefs.getString('token');
    final u = auth._prefs.getString('user');
    if (auth.token != null && u != null) auth.user = User.fromJson(jsonDecode(u) as Map<String, dynamic>);
    return auth;
  }

  Future<void> signIn(String email, String password) async {
    final (token, user) = await Api(null).login(email, password);
    this.token = token;
    await _prefs.setString('token', token);
    await setUser(user);
  }

  Future<void> setUser(User user) async {
    this.user = user;
    await _prefs.setString('user', jsonEncode(user.toJson()));
    notifyListeners();
  }

  Future<void> signOut() async {
    token = null;
    user = null;
    await _prefs.remove('token');
    await _prefs.remove('user');
    notifyListeners();
  }
}
