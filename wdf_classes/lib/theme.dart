import 'package:flutter/material.dart';

/// Design tokens — Airbnb-style system, scaled up ~1.25x so everything is big
/// and easy to tap. One accent colour (Rausch), white canvas, soft corners.
abstract final class C {
  static const primary = Color(0xFFFF385C);
  static const primaryActive = Color(0xFFE00B41);
  static const primaryDisabled = Color(0xFFFFD1DA);
  static const canvas = Color(0xFFFFFFFF);
  static const surfaceSoft = Color(0xFFF7F7F7);
  static const surfaceStrong = Color(0xFFF2F2F2);
  static const hairline = Color(0xFFDDDDDD);
  static const ink = Color(0xFF222222);
  static const body = Color(0xFF3F3F3F);
  static const muted = Color(0xFF6A6A6A);
  static const error = Color(0xFFC13515);
  static const live = Color(0xFF14A44D);
  static const stage = Color(0xFF111111);
}

abstract final class S {
  static const xs = 4.0, sm = 8.0, md = 12.0, base = 16.0, lg = 24.0, xl = 32.0, xxl = 48.0, section = 64.0;
}

abstract final class R {
  static const sm = 12.0, md = 20.0, xl = 32.0;
  static const full = 999.0;
}

/// Big tap targets everywhere.
const kButtonHeight = 60.0;
const kFieldHeight = 64.0;
const kMaxWidth = 1280.0;

const kShadow = [
  BoxShadow(color: Color(0x05000000), spreadRadius: 1),
  BoxShadow(color: Color(0x0A000000), offset: Offset(0, 2), blurRadius: 6),
  BoxShadow(color: Color(0x1A000000), offset: Offset(0, 4), blurRadius: 8),
];

abstract final class T {
  static const display = TextStyle(fontSize: 36, fontWeight: FontWeight.w700, height: 1.2, color: C.ink, letterSpacing: -0.5);
  static const title = TextStyle(fontSize: 26, fontWeight: FontWeight.w600, height: 1.25, color: C.ink, letterSpacing: -0.3);
  static const cardTitle = TextStyle(fontSize: 21, fontWeight: FontWeight.w600, height: 1.3, color: C.ink);
  static const body = TextStyle(fontSize: 18, fontWeight: FontWeight.w400, height: 1.5, color: C.body);
  static const meta = TextStyle(fontSize: 17, fontWeight: FontWeight.w400, height: 1.4, color: C.muted);
  static const label = TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.3, color: C.muted);
  static const button = TextStyle(fontSize: 19, fontWeight: FontWeight.w600, height: 1.2);
  static const badge = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, height: 1.2, letterSpacing: 0.4);
}

ThemeData buildTheme() {
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sm));
  const buttonSize = Size(64, kButtonHeight);
  const buttonPad = EdgeInsets.symmetric(horizontal: 28);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: C.canvas,
    colorScheme: ColorScheme.fromSeed(
      seedColor: C.primary,
      primary: C.primary,
      onPrimary: Colors.white,
      surface: C.canvas,
      onSurface: C.ink,
      error: C.error,
    ),
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: C.canvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: C.ink,
      elevation: 0,
      toolbarHeight: 80,
      titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 24, fontWeight: FontWeight.w700, color: C.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: C.primaryDisabled,
        disabledForegroundColor: Colors.white,
        minimumSize: buttonSize,
        padding: buttonPad,
        shape: shape,
        textStyle: T.button,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.ink,
        minimumSize: buttonSize,
        padding: buttonPad,
        shape: shape,
        side: const BorderSide(color: C.ink),
        textStyle: T.button,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: C.ink, minimumSize: const Size(48, 52), textStyle: T.button),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.canvas,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      labelStyle: T.label,
      hintStyle: T.meta,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(R.sm), borderSide: const BorderSide(color: C.hairline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.sm), borderSide: const BorderSide(color: C.hairline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.sm), borderSide: const BorderSide(color: C.ink, width: 2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(R.sm), borderSide: const BorderSide(color: C.error)),
    ),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: C.ink),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.ink,
      contentTextStyle: const TextStyle(fontFamily: 'Inter', fontSize: 17, color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.sm)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: C.canvas,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(R.md))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(R.md)),
    ),
    dividerTheme: const DividerThemeData(color: C.hairline, thickness: 1, space: 1),
  );
}

/// Centered, width-capped page body.
class PageWidth extends StatelessWidget {
  const PageWidth({super.key, required this.child, this.max = kMaxWidth});
  final Widget child;
  final double max;

  // Fills the available width up to [max] (a loose box would let content shrink and drift to the centre).
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: box.maxWidth < max ? box.maxWidth : max, child: child),
        ),
      );
}

/// Pill badge, e.g. "LIVE NOW".
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = C.canvas, this.textColor = C.ink, this.dot});
  final String text;
  final Color color, textColor;
  final Color? dot;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(R.full), boxShadow: kShadow),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) ...[
            Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            const SizedBox(width: 8),
          ],
          Text(text, style: T.badge.copyWith(color: textColor)),
        ]),
      );
}

void toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(message)));
