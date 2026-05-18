import 'package:flutter/material.dart';

import 'ipfs_photo_relay_page.dart';

class IpfsPhotoRelayApp extends StatelessWidget {
  const IpfsPhotoRelayApp({super.key, this.startNodeOnLoad = true});

  final bool startNodeOnLoad;

  @override
  Widget build(BuildContext context) {
    const canvas = Color(0xFFF5F1E8);
    const ink = Color(0xFF153243);
    const accent = Color(0xFF1F7A8C);
    const highlight = Color(0xFFF4B942);

    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    ).copyWith(
      primary: accent,
      secondary: highlight,
      surface: Colors.white,
      onPrimary: Colors.white,
      onSurface: ink,
    );

    return MaterialApp(
      title: 'IPFS Photo Relay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: canvas,
        useMaterial3: true,
        textTheme: ThemeData.light().textTheme.apply(
          bodyColor: ink,
          displayColor: ink,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: ink,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: Colors.white.withValues(alpha: 0.92),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: ink.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: IpfsPhotoRelayPage(startNodeOnLoad: startNodeOnLoad),
    );
  }
}
