import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'src/core/controllers/headphone_controller.dart';
import 'src/core/services/tray_service.dart';
import 'src/ui/screens/home_screen.dart';
import 'src/ui/theme/app_theme.dart';
import 'src/ui/theme/theme_controller.dart';
import 'src/ui/theme/system_colors.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final isTrayLaunch = args.contains('--tray') || args.contains('-t');
  final isAndroid = defaultTargetPlatform == TargetPlatform.android;

  // Initialize ThemeController and pre-load settings to avoid splash theme flashing
  final themeController = ThemeController();
  await themeController.loadSettings();

  // Initialize HeadphoneController (coordinates real Bluetooth & simulated states)
  final headphoneController = HeadphoneController(
    themeController,
    connectOnStartup: !isAndroid,
  );

  // Initialize Desktop System Tray Service (Linux / Windows)
  if (!isAndroid) {
    await TrayService(
      headphoneController: headphoneController,
      themeController: themeController,
      startHidden: isTrayLaunch,
    ).init();
  }

  runApp(
    HlControlApp(
      themeController: themeController,
      headphoneController: headphoneController,
    ),
  );
  if (isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      headphoneController.startAutoConnect();
    });
  }
}

class HlControlApp extends StatefulWidget {
  const HlControlApp({
    super.key,
    required this.themeController,
    this.systemColors,
    required this.headphoneController,
  });

  final ThemeController themeController;
  final HeadphoneController headphoneController;

  final SystemColors? systemColors;

  @override
  State<HlControlApp> createState() => _HlControlAppState();
}

class _HlControlAppState extends State<HlControlApp> {
  late SystemColors? _systemColors = widget.systemColors;
  late ThemeData _lightTheme = AppTheme.buildTheme(
    Brightness.light,
    _systemColors?.light,
  );
  late ThemeData _darkTheme = AppTheme.buildTheme(
    Brightness.dark,
    _systemColors?.dark,
  );
  AppLifecycleListener? _lifecycleListener;
  bool _readingSystemColors = false;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.android) {
      _lifecycleListener = AppLifecycleListener(onResume: () {
        widget.headphoneController.checkForConnectedDevices();
        unawaited(_refreshSystemColors());
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_refreshSystemColors());
      });
    }
  }

  Future<void> _refreshSystemColors() async {
    if (_readingSystemColors) return;
    _readingSystemColors = true;
    try {
      final colors = await loadAndroidSystemColors();
      if (mounted && colors != null && colors != _systemColors) {
        setState(() {
          _systemColors = colors;
          _lightTheme = AppTheme.buildTheme(Brightness.light, colors.light);
          _darkTheme = AppTheme.buildTheme(Brightness.dark, colors.dark);
        });
      }
    } finally {
      _readingSystemColors = false;
    }
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.themeController,
      builder: (context, _) => MaterialApp(
        title: 'Aira',
        debugShowCheckedModeBanner: false,
        theme: _lightTheme,
        darkTheme: _darkTheme,
        themeMode: widget.themeController.themeMode,
        home: HomeScreen(
          themeController: widget.themeController,
          headphoneController: widget.headphoneController,
        ),
      ),
    );
  }
}
