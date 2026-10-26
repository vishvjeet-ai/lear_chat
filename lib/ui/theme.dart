import 'package:flutter/material.dart';

const _seed = Color(0xFF00796B);

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

final lightTheme = _theme(Brightness.light);
final darkTheme = _theme(Brightness.dark);

/// Colors for chat bubbles, derived from the active scheme.
extension BubbleColors on ColorScheme {
  Color get outgoingBubble => primaryContainer;
  Color get onOutgoingBubble => onPrimaryContainer;
  Color get incomingBubble => surfaceContainerHighest;
  Color get onIncomingBubble => onSurface;
}
