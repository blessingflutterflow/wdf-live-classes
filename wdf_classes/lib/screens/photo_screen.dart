import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../main.dart';
import '../theme.dart';

/// Learners must add a clear face photo so teachers know who they are.
class PhotoScreen extends StatefulWidget {
  const PhotoScreen({super.key, this.required = false});
  final bool required;

  @override
  State<PhotoScreen> createState() => _PhotoScreenState();
}

class _PhotoScreenState extends State<PhotoScreen> {
  Uint8List? _photo;
  bool _busy = false;

  Future<void> _pick(ImageSource source) async {
    try {
      final f = await ImagePicker().pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 600,
        maxHeight: 600,
        imageQuality: 80,
      );
      if (f != null) {
        final bytes = await f.readAsBytes();
        setState(() => _photo = bytes);
      }
    } catch (e) {
      debugPrint('photo pick failed: $e');
      if (mounted) toast(context, 'Couldn\'t open the camera. Try "Choose a photo" instead.');
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await auth.setUser(await auth.api.uploadPhoto(_photo!));
      if (mounted && !widget.required) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = auth.user?.photoUrl;
    return Scaffold(
      appBar: widget.required
          ? null
          : AppBar(title: const Text('Your photo'), leading: const BackButton()),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(S.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (widget.required) ...[
                  const Text('Add your photo', style: T.display),
                  const SizedBox(height: S.sm),
                  const Text('Your teacher uses it to know who you are in class and on your assignments. Use a clear photo of your face.',
                      style: T.body),
                  const SizedBox(height: S.xl),
                ],
                Center(
                  child: Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: C.surfaceStrong,
                      border: Border.all(color: _photo != null ? C.primary : C.hairline, width: 4),
                      image: _photo != null
                          ? DecorationImage(image: MemoryImage(_photo!), fit: BoxFit.cover)
                          : current != null
                              ? DecorationImage(image: NetworkImage(current), fit: BoxFit.cover)
                              : null,
                    ),
                    child: _photo == null && current == null ? const Icon(Icons.face_rounded, size: 110, color: C.muted) : null,
                  ),
                ),
                const SizedBox(height: S.xl),
                if (_photo == null) ...[
                  FilledButton.icon(
                    onPressed: () => _pick(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_rounded, size: 28),
                    label: const Text('Take a selfie'),
                  ),
                  const SizedBox(height: S.md),
                  OutlinedButton.icon(
                    onPressed: () => _pick(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_rounded, size: 26),
                    label: const Text('Choose a photo'),
                  ),
                ] else ...[
                  FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Use this photo')),
                  const SizedBox(height: S.md),
                  OutlinedButton(onPressed: _busy ? null : () => setState(() => _photo = null), child: const Text('Try again')),
                ],
                if (widget.required) ...[
                  const SizedBox(height: S.lg),
                  TextButton(onPressed: auth.signOut, child: const Text('Sign out')),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
