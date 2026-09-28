import 'package:flutter/material.dart';

import '../main.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await auth.signIn(_email.text.trim(), _password.text);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(S.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: C.primary, shape: BoxShape.circle),
                      child: const Icon(Icons.school_rounded, color: Colors.white, size: 38),
                    ),
                    const SizedBox(height: S.lg),
                    const Text('Welcome to\nWDF Classes', style: T.display),
                    const SizedBox(height: S.sm),
                    const Text('Learners: use the username and password your graduate gave you. Graduates: use your app.wdf.church login.', style: T.body),
                    const SizedBox(height: S.xl),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.visiblePassword, // no auto-capitals / spaces
                      autocorrect: false,
                      autofillHints: const [AutofillHints.username],
                      textInputAction: TextInputAction.next,
                      style: const TextStyle(fontSize: 19, color: C.ink),
                      decoration: const InputDecoration(labelText: 'Username, email or cell number'),
                    ),
                    const SizedBox(height: S.base),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(fontSize: 19, color: C.ink),
                      decoration: const InputDecoration(labelText: 'Password'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: S.md),
                      Text(_error!, style: T.meta.copyWith(color: C.error)),
                    ],
                    const SizedBox(height: S.lg),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox.square(dimension: 26, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white))
                          : const Text('Sign in'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}
