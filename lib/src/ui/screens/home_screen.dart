import 'dart:convert';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/constants/build_commit.dart';
import '../../core/controllers/headphone_controller.dart';
import '../../core/models/bluetooth_device.dart';
import '../../core/models/headphone_status.dart';
import '../../core/services/freebuds_service.dart';
import '../../core/services/simulation_service.dart';
import '../theme/theme_controller.dart';
import '../widgets/anc_selector.dart';
import '../widgets/earbud_battery_icon.dart';
import '../widgets/earbud_cloud.dart';
import '../widgets/shutdown_timer_card.dart';
import '../widgets/eq_selector.dart';
import '../widgets/expressive_popup.dart';
import '../widgets/expressive_list_group.dart';
import '../widgets/paired_devices_section.dart';
import 'freebuds_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.themeController,
    required this.headphoneController,
  });

  final ThemeController themeController;
  final HeadphoneController headphoneController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  static const _tabMotionMilliseconds = 320;

  late final _tabTransition = AnimationController.unbounded(vsync: this);
  final _tabSlide = Tween(begin: Offset.zero, end: Offset.zero);
  late final _tabOffset = _tabTransition.drive(_tabSlide);
  static final _titleBlur = ImageFilter.blur(sigmaX: 16, sigmaY: 16);

  final _selectedTab = ValueNotifier(0);
  final _tabScroll = List.generate(_tabLabels.length, (_) => ValueNotifier(0.0));
  int get _currentTab => _selectedTab.value;
  final _visitedTabs = <int>{0};
  late final _tabScrollControllers = List.generate(
    _tabLabels.length,
    (_) => ScrollController(),
  );
  bool _isRailExpanded = true;
  bool _openingDevicePicker = false;
  bool _checkingLocator = false;
  bool _ancLevelExpanded = false;
  int _buildTapCount = 0;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  static const _tabLabels = ['Control', 'Device', 'Settings'];
  static const _tabIcons = [Icons.tune, Icons.devices_rounded, Icons.settings];

  // Getters from HeadphoneController
  HeadphoneStatus get _status => widget.headphoneController.status;
  bool get _isConnected => widget.headphoneController.isConnected;
  bool get _isConnecting => widget.headphoneController.isConnecting;
  String get _deviceName => widget.headphoneController.deviceName;
  int get _batteryPercent => widget.headphoneController.batteryPercent;

  // Optimistic UI state overrides and in-flight lock tracking
  final Map<String, dynamic> _optimisticOverrides = {};
  final Set<String> _inFlightControls = {};

  Future<void> _executeOptimisticAction<T>({
    required String controlKey,
    required String controlName,
    required T newValue,
    required T currentValue,
    required Future<void> Function() action,
    Duration? timeout = const Duration(seconds: 4),
  }) async {
    if (_inFlightControls.contains(controlKey)) return;

    setState(() {
      _inFlightControls.add(controlKey);
      _optimisticOverrides[controlKey] = newValue;
    });

    try {
      final pending = action();
      await (timeout == null ? pending : pending.timeout(timeout));
    } catch (e) {
      if (mounted) {
        setState(() {
          _optimisticOverrides.remove(controlKey);
        });

        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update $controlName'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _inFlightControls.remove(controlKey);
          _optimisticOverrides.remove(controlKey);
        });
      }
    }
  }

  String get _selectedAncMode {
    if (_optimisticOverrides.containsKey('anc_mode')) {
      return _optimisticOverrides['anc_mode'] as String;
    }
    final mode = widget.headphoneController.status.ancMode;
    if (mode.contains('Normal') || mode.contains('Off')) return 'Normal';
    if (mode.contains('Adaptive')) return 'Adaptive';
    if (mode.contains('ANC')) return 'ANC On';
    if (mode.contains('Transparency') || mode.contains('Aware')) {
      return 'Transparency';
    }
    return 'Normal';
  }

  int get _selectedAncIntensity {
    if (_optimisticOverrides.containsKey('anc_intensity')) {
      return _optimisticOverrides['anc_intensity'] as int;
    }
    return widget.headphoneController.status.ancIntensity;
  }

  String get _selectedEqPreset {
    if (_optimisticOverrides.containsKey('eq_preset')) {
      return _optimisticOverrides['eq_preset'] as String;
    }
    return widget.headphoneController.status.eqPreset;
  }

  bool get _gameMode {
    if (_optimisticOverrides.containsKey('game_mode')) {
      return _optimisticOverrides['game_mode'] as bool;
    }
    return widget.headphoneController.status.gameMode ?? false;
  }

  bool get _windNoiseReduction {
    if (_optimisticOverrides.containsKey('wind_noise')) {
      return _optimisticOverrides['wind_noise'] as bool;
    }
    return widget.headphoneController.status.windNoise ?? false;
  }

  bool get _multipoint {
    if (_optimisticOverrides.containsKey('multipoint')) {
      return _optimisticOverrides['multipoint'] as bool;
    }
    return widget.headphoneController.status.multipoint ?? false;
  }

  bool get _ldac {
    if (_optimisticOverrides.containsKey('ldac')) {
      return _optimisticOverrides['ldac'] as bool;
    }
    return widget.headphoneController.status.ldac ?? false;
  }

  String get _spatialAudioMode {
    if (_optimisticOverrides.containsKey('spatial_audio')) {
      return _optimisticOverrides['spatial_audio'] as String;
    }
    final mode = widget.headphoneController.status.spatialAudioMode;
    if (mode.contains('Dynamic')) return 'Dynamic';
    if (mode.contains('Static')) return 'Static';
    return 'Off';
  }

  String get _spatialScene {
    if (_optimisticOverrides.containsKey('spatial_scene')) {
      return _optimisticOverrides['spatial_scene'] as String;
    }
    final scene = widget.headphoneController.status.spatialScene;
    if (scene.contains('Sport')) return 'Sport';
    if (scene.contains('Movie')) return 'Movie';
    return 'Music';
  }

  bool get _wearDetection {
    if (_optimisticOverrides.containsKey('wear_detection')) {
      return _optimisticOverrides['wear_detection'] as bool;
    }
    return widget.headphoneController.status.wearDetection ?? false;
  }

  bool get _antiLeak {
    if (_optimisticOverrides.containsKey('anti_leak')) {
      return _optimisticOverrides['anti_leak'] as bool;
    }
    return widget.headphoneController.status.antiLeak ?? false;
  }

  int get _autoShutdownIndex {
    if (_optimisticOverrides.containsKey('auto_shutdown')) {
      return _optimisticOverrides['auto_shutdown'] as int;
    }
    return widget.headphoneController.status.autoShutdownIndex ?? 4;
  }
  final List<String> _shutdownOptions = ['30 min', '1 hour', '3 hours', '5 hours', 'Never'];
  static const List<String> _shutdownTickLabels = ['30m', '1h', '3h', '5h', 'Never'];

  // Custom EQ states (10-band slider values from -12 to +12 dB)
  final List<double> _eqValues = List.filled(10, 0.0);
  final List<String> _eqBands = [
    '31Hz', '62Hz', '125Hz', '250Hz', '500Hz',
    '1kHz', '2kHz', '4kHz', '8kHz', '16kHz'
  ];
  bool _showEqSliders = false;

  // Custom EQ presets list
  final List<Map<String, dynamic>> _customPresets = [
    {
      'name': 'Vocal booster',
      'values': [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0, 3.0, 2.0, 1.0],
    },
    {
      'name': 'Electronic',
      'values': [5.0, 4.0, 1.0, -1.0, -2.0, 1.0, 3.0, 4.0, 5.0, 5.0],
    },
  ];

  static const Map<String, List<double>> _presetValues = {
    'Default': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Vocal': [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 3.5, 3.0, 2.0, 1.0],
    'Rock': [4.0, 3.0, -1.0, -2.0, 0.0, 1.0, 2.0, 3.0, 4.0, 4.0],
    'Classical': [3.0, 2.0, 1.5, 1.0, -1.0, -1.5, 1.0, 2.0, 2.5, 3.0],
    'Popularity': [1.0, 2.0, 3.0, 2.0, 0.0, -1.0, 1.0, 2.0, 3.0, 2.0],
    'Bass': [5.0, 4.0, 3.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Subwoofer': [6.0, 5.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Soft': [-2.0, -1.0, 0.0, 1.0, 2.0, 2.0, 1.0, 0.0, -1.0, -2.0],
    'Outdoor': [3.0, 2.0, 0.0, 0.0, 1.0, 2.0, 3.0, 3.0, 2.0, 1.0],
  };

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _tabScrollControllers.length; i++) {
      final scroll = _tabScrollControllers[i];
      scroll.addListener(() {
        if (scroll.hasClients) {
          _tabScroll[i].value = (scroll.offset / 48).clamp(0.0, 1.0);
        }
      });
    }
    _loadCustomPresets();
  }

  @override
  void dispose() {
    for (final progress in _tabScroll) {
      progress.dispose();
    }
    _tabTransition.dispose();
    _selectedTab.dispose();
    for (final controller in _tabScrollControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCustomPresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString('custom_eq_presets');
      if (jsonStr != null) {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        if (mounted) {
          setState(() {
            _customPresets.clear();
            for (final item in decoded) {
              if (item is Map) {
                _customPresets.add({
                  'name': item['name'] as String,
                  'values': (item['values'] as List<dynamic>).map((e) => (e as num).toDouble()).toList(),
                });
              }
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCustomPresetsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_customPresets);
      await prefs.setString('custom_eq_presets', jsonStr);
    } catch (_) {}
  }

  void _showSavePresetDialog() {
    if (!_isConnected) return;
    final textController = TextEditingController();
    showExpressiveDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Save custom preset'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: 'Preset name (e.g. My bass)',
              border: OutlineInputBorder(),
            ),
            maxLength: 20,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = textController.text.trim();
              if (name.isNotEmpty) {
                setState(() {
                  _customPresets.removeWhere((p) => p['name'] == name);
                  _customPresets.add({
                    'name': name,
                    'values': List<double>.from(_eqValues),
                  });
                });
                _saveCustomPresetsToPrefs();
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showDeletePresetDialog(Map<String, dynamic> preset) {
    if (!_isConnected) return;
    final name = preset['name'] as String;
    showExpressiveDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error, size: 28),
        title: const Text('Delete preset'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Text(
            'Are you sure you want to delete the custom preset "$name"?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              setState(() {
                _customPresets.remove(preset);
              });
              _saveCustomPresetsToPrefs();
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  bool _isFindingDevice = false;

  void _showRenameDialog() {
    if (!_isConnected) return;
    final textController = TextEditingController(text: _deviceName);
    showExpressiveDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Rename device'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: TextField(
            controller: textController,
            decoration: const InputDecoration(
              hintText: 'Enter new device name',
              border: OutlineInputBorder(),
            ),
            maxLength: 30,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (textController.text.trim().isNotEmpty) {
                widget.headphoneController.renameDevice(textController.text.trim());
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showGestureConfigDialog() {
    if (!_isConnected || !_status.hasGestures) return;

    int selectedGestureType = 1; // 1=Double Tap, 2=Triple Tap, 3=Long Press

    const gestureFunctions = <int, String>{
      0: 'Voice assistant',
      1: 'Play / pause',
      2: 'Previous track',
      3: 'Next track',
      4: 'Volume up',
      5: 'Volume down',
      6: 'Cycle ANC mode',
      7: 'Low-latency game mode',
      255: 'Disabled',
    };

    final gestures = _status.gestures ?? {};
    int leftFunc = (gestures['1']?['left_func'] as num?)?.toInt() ?? 1;
    int rightFunc = (gestures['1']?['right_func'] as num?)?.toInt() ?? 3;

    showExpressiveDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);

            void updateSelectedType(int type) {
              final typeKey = type.toString();
              setDialogState(() {
                selectedGestureType = type;
                leftFunc =
                    (gestures[typeKey]?['left_func'] as num?)?.toInt() ??
                    (type == 1 ? 1 : 255);
                rightFunc =
                    (gestures[typeKey]?['right_func'] as num?)?.toInt() ??
                    (type == 1 ? 3 : 255);
              });
            }

            return AlertDialog(
              scrollable: true,
              backgroundColor: theme.colorScheme.surfaceContainerLow,
              icon: Icon(
                Icons.touch_app,
                color: theme.colorScheme.primary,
                size: 28,
              ),
              title: const Text('Touch gestures', textAlign: TextAlign.center),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        padding: WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                        ),
                      ),
                      segments: const [
                        ButtonSegment(
                          value: 1,
                          label: Text(
                            'Double tap',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        ButtonSegment(
                          value: 2,
                          label: Text(
                            'Triple tap',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        ButtonSegment(
                          value: 3,
                          label: Text(
                            'Long press',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      selected: {selectedGestureType},
                      onSelectionChanged: (selection) =>
                          updateSelectedType(selection.first),
                    ),
                    const SizedBox(height: 16),
                    ExpressiveListGroup(
                      children: [
                        ExpressiveOptionPicker<int>(
                          label: 'Left earbud',
                          value: leftFunc,
                          actions: gestureFunctions,
                          onSelected: (value) =>
                              setDialogState(() => leftFunc = value),
                        ),
                        ExpressiveOptionPicker<int>(
                          label: 'Right earbud',
                          value: rightFunc,
                          actions: gestureFunctions,
                          onSelected: (value) =>
                              setDialogState(() => rightFunc = value),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await widget.headphoneController.setGesture(
                      selectedGestureType,
                      leftFunc,
                      rightFunc,
                    );
                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(
                        content: Text('Touch gesture updated.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _toggleFindDevice() async {
    if (!_isConnected) return;
    final newPlaying = !_isFindingDevice;
    setState(() {
      _isFindingDevice = newPlaying;
    });
    await widget.headphoneController.findDevice(newPlaying);
    if (mounted && newPlaying) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Ringing headphones... Tap to stop.'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Stop',
            onPressed: () {
              _toggleFindDevice();
            },
          ),
        ),
      );
    }
  }

  void _showRebootWarningDialog({
    required String title,
    required String message,
    required String confirmLabel,
    IconData icon = Icons.restart_alt,
    required VoidCallback onConfirm,
  }) {
    showExpressiveDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          scrollable: true,
          icon: Icon(icon, color: theme.colorScheme.primary, size: 28),
          title: Text(title, textAlign: TextAlign.center),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'The headphones will disconnect and restart (~3–5 sec) to apply changes.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                onConfirm();
              },
              child: Text(confirmLabel),
            ),
          ],
        );
      },
    );
  }

  void _handleAncModeChanged(String mode) {
    if (!_isConnected || _inFlightControls.contains('anc_mode')) return;
    int modeVal = 0;
    if (mode == 'ANC On') {
      modeVal = 1;
    } else if (mode == 'Transparency') {
      modeVal = 2;
    } else if (mode == 'Adaptive') {
      modeVal = 4;
    }
    _executeOptimisticAction<String>(
      controlKey: 'anc_mode',
      controlName: 'ANC mode',
      newValue: mode,
      currentValue: _selectedAncMode,
      action: () => widget.headphoneController.setAncMode(modeVal),
    );
  }

  void _handleAncIntensityChanged(int level) {
    if (!_isConnected || _inFlightControls.contains('anc_intensity')) return;
    _executeOptimisticAction<int>(
      controlKey: 'anc_intensity',
      controlName: 'ANC level',
      newValue: level,
      currentValue: _selectedAncIntensity,
      action: () => widget.headphoneController.setAncLevel(level),
    );
  }

  void _handleEqPresetChanged(String preset) {
    if (!_isConnected || _inFlightControls.contains('eq_preset')) return;
    final presets = _status.eqType == 's40'
        ? EqSelector.defaultS40Presets
        : EqSelector.standardPresets;
    final idx = presets.indexOf(preset);
    if (idx != -1) {
      final vals = _presetValues[preset];
      if (vals != null) {
        setState(() {
          for (int i = 0; i < 10; i++) {
            _eqValues[i] = vals[i];
          }
        });
      }
      _executeOptimisticAction<String>(
        controlKey: 'eq_preset',
        controlName: 'EQ preset',
        newValue: preset,
        currentValue: _selectedEqPreset,
        action: () => widget.headphoneController.setEqPreset(idx),
      );
    }
  }

  void _setAutoShutdownSeconds(int seconds, int unitSeconds) {
    final software = widget.headphoneController.usesSoftwareShutdown;
    if (!_isConnected ||
        (!software &&
            (!_status.hasAutoShutdown ||
                seconds == _status.autoShutdownSeconds))) {
      return;
    }
    _executeOptimisticAction<int?>(
      controlKey: 'auto_shutdown',
      controlName: 'auto shutdown timer',
      newValue: seconds,
      currentValue: _status.autoShutdownSeconds,
      action: () async {
        await widget.headphoneController.setAutoShutdownSeconds(seconds);
        if (seconds > 0) {
          await widget.themeController.saveShutdownTimerInput(
            seconds,
            unitSeconds,
          );
        }
      },
      timeout: null,
    );
  }

  void _handleAutoShutdownChanged(int choiceIdx) {
    if (!_isConnected || _inFlightControls.contains('auto_shutdown')) return;
    _executeOptimisticAction<int>(
      controlKey: 'auto_shutdown',
      controlName: 'auto shutdown timer',
      newValue: choiceIdx,
      currentValue: _autoShutdownIndex,
      action: () => widget.headphoneController.setAutoShutdown(choiceIdx),
    );
  }

  void _handleWindNoiseChanged(bool val) {
    if (!_isConnected || _inFlightControls.contains('wind_noise')) return;
    _executeOptimisticAction<bool>(
      controlKey: 'wind_noise',
      controlName: 'wind noise reduction',
      newValue: val,
      currentValue: _windNoiseReduction,
      action: () => widget.headphoneController.setWindNoise(val),
    );
  }

  void _handleWearDetectionChanged(bool val) {
    if (!_isConnected || _inFlightControls.contains('wear_detection')) return;
    _executeOptimisticAction<bool>(
      controlKey: 'wear_detection',
      controlName: 'smart wear detection',
      newValue: val,
      currentValue: _wearDetection,
      action: () => widget.headphoneController.setWearDetection(val),
    );
  }

  void _handleAntiLeakChanged(bool val) {
    if (!_isConnected || _inFlightControls.contains('anti_leak')) return;
    _executeOptimisticAction<bool>(
      controlKey: 'anti_leak',
      controlName: 'anti-sound leak',
      newValue: val,
      currentValue: _antiLeak,
      action: () => widget.headphoneController.setAntiLeak(val),
    );
  }

  void _handleSpatialSceneChanged(String scene) {
    if (!_isConnected || _inFlightControls.contains('spatial_scene')) return;
    final idx = ['Music', 'Sport', 'Movie'].indexOf(scene);
    if (idx != -1) {
      _executeOptimisticAction<String>(
        controlKey: 'spatial_scene',
        controlName: 'spatial scene',
        newValue: scene,
        currentValue: _spatialScene,
        action: () => widget.headphoneController.setSpatialScene(idx),
      );
    }
  }

  void _handleLdacChanged(bool val) {
    if (!_isConnected || _inFlightControls.contains('ldac')) return;
    if (val) {
      final List<String> conflicts = [];
      if (_multipoint) conflicts.add('multipoint connection');
      if (_gameMode) conflicts.add('game mode');
      if (_spatialAudioMode != 'Off') conflicts.add('spatial audio');

      String explanation = 'Enabling LDAC high-resolution audio provides maximum audio fidelity (up to 990 kbps).';
      if (conflicts.isNotEmpty) {
        explanation += '\n\nNote: LDAC cannot run simultaneously with ${conflicts.join(', ')}. Enabling LDAC will turn off ${conflicts.join(' and ')}.';
      }

      _showRebootWarningDialog(
        title: 'Enable LDAC audio codec?',
        message: explanation,
        confirmLabel: 'Enable & restart',
        icon: Icons.high_quality,
        onConfirm: () {
          _executeOptimisticAction<bool>(
            controlKey: 'ldac',
            controlName: 'LDAC audio codec',
            newValue: true,
            currentValue: _ldac,
            action: () => widget.headphoneController.setLdac(true),
          );
        },
      );
    } else {
      _showRebootWarningDialog(
        title: 'Disable LDAC audio codec?',
        message: 'Disabling LDAC will switch streaming back to standard audio codecs (AAC/SBC).',
        confirmLabel: 'Disable & restart',
        icon: Icons.high_quality,
        onConfirm: () {
          _executeOptimisticAction<bool>(
            controlKey: 'ldac',
            controlName: 'LDAC audio codec',
            newValue: false,
            currentValue: _ldac,
            action: () => widget.headphoneController.setLdac(false),
          );
        },
      );
    }
  }

  void _handleMultipointChanged(bool val) {
    if (!_isConnected || _inFlightControls.contains('multipoint')) return;
    if (val && _ldac) {
      _showRebootWarningDialog(
        title: 'Enable multipoint connection?',
        message: 'Multipoint (dual-device connection) cannot be used simultaneously with LDAC high-resolution audio.\n\nEnabling multipoint will disable LDAC.',
        confirmLabel: 'Turn off LDAC & enable',
        icon: Icons.link,
        onConfirm: () {
          _executeOptimisticAction<bool>(
            controlKey: 'multipoint',
            controlName: 'multipoint connection',
            newValue: true,
            currentValue: _multipoint,
            action: () => widget.headphoneController.setMultipoint(true),
          );
        },
      );
    } else {
      _executeOptimisticAction<bool>(
        controlKey: 'multipoint',
        controlName: 'multipoint connection',
        newValue: val,
        currentValue: _multipoint,
        action: () => widget.headphoneController.setMultipoint(val),
      );
    }
  }

  void _handleGameModeChanged(bool val) {
    if (!_isConnected || _inFlightControls.contains('game_mode')) return;
    if (val && _ldac) {
      _showRebootWarningDialog(
        title: 'Enable game mode?',
        message: 'Low-latency game mode cannot be used simultaneously with LDAC high-resolution audio.\n\nEnabling game mode will disable LDAC.',
        confirmLabel: 'Turn off LDAC & enable',
        icon: Icons.sports_esports,
        onConfirm: () {
          _executeOptimisticAction<bool>(
            controlKey: 'game_mode',
            controlName: 'game mode',
            newValue: true,
            currentValue: _gameMode,
            action: () => widget.headphoneController.setGameMode(true),
          );
        },
      );
    } else {
      _executeOptimisticAction<bool>(
        controlKey: 'game_mode',
        controlName: 'game mode',
        newValue: val,
        currentValue: _gameMode,
        action: () => widget.headphoneController.setGameMode(val),
      );
    }
  }

  void _handleSpatialAudioChanged(String mode) {
    if (!_isConnected || _inFlightControls.contains('spatial_audio')) return;
    if (mode != 'Off' && _ldac) {
      _showRebootWarningDialog(
        title: 'Enable spatial audio ($mode)?',
        message: 'Spatial audio DSP processing cannot be used simultaneously with LDAC high-resolution audio.\n\nEnabling spatial audio will disable LDAC.',
        confirmLabel: 'Turn off LDAC & enable',
        icon: Icons.spatial_audio,
        onConfirm: () {
          _executeOptimisticAction<String>(
            controlKey: 'spatial_audio',
            controlName: 'spatial audio',
            newValue: mode,
            currentValue: _spatialAudioMode,
            action: () => widget.headphoneController.setSpatialAudio(mode),
          );
        },
      );
    } else {
      _executeOptimisticAction<String>(
        controlKey: 'spatial_audio',
        controlName: 'spatial audio',
        newValue: mode,
        currentValue: _spatialAudioMode,
        action: () => widget.headphoneController.setSpatialAudio(mode),
      );
    }
  }

  Widget _buildTitleBackdrop(int tab) {
    const background = SizedBox.expand();
    return ValueListenableBuilder(
      valueListenable: _tabScroll[tab],
      child: background,
      builder: (context, scroll, child) {
        if (scroll == 0) return child!;
        final sigma = 16 * Curves.easeOut.transform(scroll);
        return ClipRect(
          child: BackdropFilter(
            filter: scroll == 1
                ? _titleBlur
                : ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 650;
        final hasAppBar = _isAndroid || !isWide;
        // The simulator in developer settings shows the live connection state.
        return ListenableBuilder(
          listenable: widget.headphoneController,
          child: widget.themeController.isDeveloperMode
              ? null
              : _buildSettingsTab(theme, isWide: isWide),
          builder: (context, settings) {
            final tabs = [
              _buildControlTab(theme, isWide: isWide),
              _buildDeviceTab(theme, isWide: isWide),
              settings ?? _buildSettingsTab(theme, isWide: isWide),
            ];

            return ValueListenableBuilder(
              valueListenable: _selectedTab,
              builder: (context, tab, _) {
                return Scaffold(
                  extendBodyBehindAppBar: hasAppBar,
                  appBar: hasAppBar
                      ? AppBar(
                          centerTitle: false,
                          title: Text(
                            tab == 0 ? 'Aira' : _tabLabels[tab],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          backgroundColor: Colors.transparent,
                          forceMaterialTransparency: true,
                          notificationPredicate: (_) => false,
                          flexibleSpace: _buildTitleBackdrop(tab),
                          surfaceTintColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          elevation: 0,
                          scrolledUnderElevation: 0,
                          systemOverlayStyle:
                              theme.brightness == Brightness.dark
                              ? SystemUiOverlayStyle.light
                              : SystemUiOverlayStyle.dark,
                          actions: [
                            if (tab == 0) _connectionAction(),
                          ],
                        )
                      : null,
                  body: isWide
                      ? Row(
                          children: [
                            if (_isAndroid)
                              _buildAndroidRail()
                            else
                              _buildSidebar(theme),
                            Expanded(
                              child: SafeArea(
                                top: !hasAppBar,
                                left: false,
                                child: _buildAnimatedTab(tabs),
                              ),
                            ),
                          ],
                        )
                      : SafeArea(
                          top: false,
                          bottom: false,
                          child: _buildAnimatedTab(tabs),
                        ),
                  bottomNavigationBar: isWide
                      ? null
                      : NavigationBar(
                          animationDuration: _motionDuration(
                            _tabMotionMilliseconds,
                          ),
                          selectedIndex: tab,
                          onDestinationSelected: _selectTab,
                          destinations: [
                            for (var i = 0; i < _tabLabels.length; i++)
                              NavigationDestination(
                                icon: Icon(_tabIcons[i]),
                                label: _tabLabels[i],
                              ),
                          ],
                        ),
                );
              },
            );
          },
        );
      },
    );
  }

  void _selectTab(int index) {
    if (index == _currentTab) return;
    final direction = index > _currentTab ? 1 : -1;
    _visitedTabs.add(index);
    _selectedTab.value = index;
    if (MediaQuery.disableAnimationsOf(context)) {
      _tabTransition.value = 0;
    } else {
      _tabSlide.end = Offset(direction * 0.025, 0);
      _tabTransition.animateWith(
        ScrollSpringSimulation(
          Springs.expressiveDefaultSpatial,
          1,
          0,
          0,
          tolerance: const Tolerance(distance: 0.004, velocity: 0.04),
        ),
      );
    }
  }

  Widget _connectionAction() => IconButton(
    icon: Icon(
      _isConnected ? Icons.bluetooth_disabled : Icons.bluetooth_searching,
    ),
    tooltip: _isConnected ? 'Disconnect earbuds' : 'Connect device',
    onPressed: _isConnected ? _confirmDisconnect : _connectDevice,
  );

  Future<void> _confirmDisconnect() async {
    if (!_isConnected) return;
    final name = _deviceName;
    final mac = widget.themeController.lastConnectedMac;
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.bluetooth_disabled),
        title: const Text('Disconnect earbuds'),
        content: Text('Disconnect from $name?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !_isConnected ||
        mac != widget.themeController.lastConnectedMac) {
      return;
    }
    final controller = widget.headphoneController;
    final disconnected = await controller.disconnect();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            disconnected
                ? 'Disconnected from $name'
                : 'Bluetooth audio may still be connected.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Widget _buildAndroidRail() {
    return SafeArea(
      child: NavigationRail(
        selectedIndex: _currentTab,
        onDestinationSelected: _selectTab,
        labelType: NavigationRailLabelType.all,
        scrollable: true,
        destinations: [
          for (var i = 0; i < _tabLabels.length; i++)
            NavigationRailDestination(
              icon: Icon(_tabIcons[i]),
              label: Text(_tabLabels[i]),
            ),
        ],
      ),
    );
  }

  Future<void> _connectDevice() async {
    if (_openingDevicePicker || _isConnecting) return;
    _openingDevicePicker = true;
    try {
      final controller = widget.headphoneController;
      final device = await showExpressiveDialog<BluetoothDevice>(
        context: context,
        builder: (_) => _DeviceSelectionDialog(headphoneController: controller),
      );
      if (!mounted || device == null) return;
      final ready = await controller.connectFromPicker(
        device.macAddress,
        device.name,
      );
      if (!mounted || ready) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t connect Bluetooth audio.')),
      );
    } finally {
      _openingDevicePicker = false;
    }
  }

  Widget _disconnectedPreview(Widget child) {
    final disconnected = !_isConnected;
    final connect = disconnected ? _connectDevice : null;
    return Opacity(
      opacity: disconnected ? 0.55 : 1,
      child: Semantics(
        button: disconnected ? true : null,
        excludeSemantics: disconnected,
        onTap: connect,
        child: MouseRegion(
          cursor: disconnected ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: disconnected
                ? HitTestBehavior.opaque
                : HitTestBehavior.deferToChild,
            excludeFromSemantics: true,
            onTap: connect,
            child: AbsorbPointer(absorbing: disconnected, child: child),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebar(ThemeData theme) {
    final sidebarWidth = _isRailExpanded ? 240.0 : 76.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: sidebarWidth,
      clipBehavior: Clip.hardEdge,
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0,
          maxWidth: 240.0,
          child: SizedBox(
            width: _isRailExpanded ? 240.0 : 76.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
              child: SizedBox(
                height: 48,
                child: _isRailExpanded
                    ? Row(
                        children: [
                          Container(
                            width: 56,
                            height: 48,
                            alignment: Alignment.center,
                            child: IconButton(
                              icon: const Icon(Icons.menu_open_rounded),
                              tooltip: 'Collapse sidebar',
                              onPressed: () => setState(() => _isRailExpanded = false),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'Aira',
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onSurface,
                                letterSpacing: -0.2,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Center(
                        child: Container(
                          width: 56,
                          height: 48,
                          alignment: Alignment.center,
                          child: IconButton(
                            icon: const Icon(Icons.menu_rounded),
                            tooltip: 'Expand sidebar',
                            onPressed: () => setState(() => _isRailExpanded = true),
                          ),
                        ),
                      ),
              ),
            ),
            _SidebarItem(
              icon: _currentTab == 0 ? Icons.tune_rounded : Icons.tune_outlined,
              label: 'Control',
              index: 0,
              selectedIndex: _currentTab,
              isExpanded: _isRailExpanded,
              onTap: () => _selectTab(0),
            ),
            _SidebarItem(
              icon: _currentTab == 1 ? Icons.devices_rounded : Icons.devices_outlined,
              label: _tabLabels[1],
              index: 1,
              selectedIndex: _currentTab,
              isExpanded: _isRailExpanded,
              onTap: () => _selectTab(1),
            ),
            _SidebarItem(
              icon: _currentTab == 2 ? Icons.settings_rounded : Icons.settings_outlined,
              label: 'Settings',
              index: 2,
              selectedIndex: _currentTab,
              isExpanded: _isRailExpanded,
              onTap: () => _selectTab(2),
            ),
            const Spacer(),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: (_isConnected && _currentTab != 0)
                  ? Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: _isRailExpanded
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainer,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _deviceName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.labelMedium?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: theme.colorScheme.onSurface,
                                          ),
                                        ),
                                        if (_batteryPercent > 0)
                                          Text(
                                            '$_batteryPercent% battery',
                                            style: theme.textTheme.labelSmall?.copyWith(
                                              color: theme.colorScheme.onSurfaceVariant,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Center(
                              child: Tooltip(
                                message: '$_deviceName (${_batteryPercent > 0 ? '$_batteryPercent%' : 'Connected'})',
                                child: Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surfaceContainer,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Icon(
                                        Icons.headphones_rounded,
                                        size: 20,
                                        color: theme.colorScheme.primary,
                                      ),
                                      Positioned(
                                        right: 6,
                                        top: 6,
                                        child: Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  ),
);
  }

  Duration _motionDuration(int milliseconds) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Duration(milliseconds: milliseconds);

  Widget _animateSize(Widget child) {
    final duration = _motionDuration(150);
    if (duration == Duration.zero) return child;
    return AnimatedSize(
      duration: duration,
      alignment: Alignment.topCenter,
      curve: Curves.easeOutCubic,
      child: child,
    );
  }

  Widget _buildAnimatedTab(List<Widget> tabs) {
    return ClipRect(
      child: SlideTransition(
        position: _tabOffset,
        textDirection: Directionality.of(context),
        child: IndexedStack(
          index: _currentTab,
          sizing: StackFit.expand,
          children: [
            for (var index = 0; index < tabs.length; index++)
              if (_visitedTabs.contains(index))
                TickerMode(
                  enabled: index == _currentTab,
                  child: ExcludeFocus(
                    excluding: index != _currentTab,
                    child: RepaintBoundary(child: tabs[index]),
                  ),
                )
              else
                const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  Widget _buildCenteredScrollable({
    required int tab,
    required double availableWidth,
    required List<Widget> children,
    required EdgeInsets padding,
    required bool isWide,
    double maxWidth = 580,
    Widget? deviceHero,
  }) {
    final bottomInset = _isAndroid ? 0.0 : MediaQuery.paddingOf(context).bottom;
    final gutter = availableWidth > maxWidth
        ? (availableWidth - maxWidth) / 2
        : 0.0;
    final insets = isWide ? const EdgeInsets.fromLTRB(24, 24, 24, 80) : padding;

    return Builder(
      builder: (context) {
        final top = insets.top + MediaQuery.paddingOf(context).top;
        return CustomScrollView(
          key: PageStorageKey(tab),
          controller: _tabScrollControllers[tab],
          primary: false,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                gutter + insets.left,
                deviceHero == null ? top : 0,
                gutter + insets.right,
                insets.bottom + bottomInset,
              ),
              sliver: SliverList.list(
                children: [
                  if (deviceHero != null)
                    EarbudCloud(
                      child: Padding(
                        padding: EdgeInsets.only(top: top, bottom: 28),
                        child: deviceHero,
                      ),
                    ),
                  ...children,
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // The keyboard changes the viewport height on every animation frame.
  // Keep the tab contents while the scroll view adjusts its own viewport.
  Widget _widthLayout(Widget Function(double width) buildForWidth) {
    double? lastWidth;
    Widget? contents;
    return LayoutBuilder(
      builder: (_, constraints) {
        if (contents == null || lastWidth != constraints.maxWidth) {
          lastWidth = constraints.maxWidth;
          contents = buildForWidth(constraints.maxWidth);
        }
        return contents!;
      },
    );
  }

  // --- CONTROL TAB ---
  Widget _buildControlTab(ThemeData theme, {required bool isWide}) {
    return _widthLayout((width) {
      final is2Pane = width >= 720;
      final status = _status;
      final hasAudioFeatures =
          !_isConnected ||
          status.gameMode != null ||
          (status.hasAnc && status.windNoise != null) ||
          status.multipoint != null ||
          status.hasLdac ||
          (status.hasWearDetection && status.wearDetection != null) ||
          status.hasAntiLeak ||
          status.hasSpatialAudio;
      final showNoiseControl = !_isConnected || status.hasAnc;
      final canManagePairedDevices =
          _isConnected && widget.headphoneController.hasFreeBudsControls;
      final hasTimer =
          _isAndroid ||
          (_isConnected &&
              status.hasAutoShutdown &&
              status.autoShutdownIndex != null);

      final noiseColumn = [
        if (!_isConnected ||
            canManagePairedDevices ||
            (_isAndroid && status.modelInfo == null))
          _animateSize(
            _disconnectedPreview(
              PairedDevicesSection(
                controller: widget.headphoneController,
                enabled: canManagePairedDevices,
              ),
            ),
          ),
        if (showNoiseControl) _disconnectedPreview(_buildNoiseControls(theme)),
      ];
      final sections = [
        if (noiseColumn.isNotEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 24,
            children: noiseColumn,
          ),
        if (hasAudioFeatures)
          _disconnectedPreview(
            _buildControlSection(
              theme,
              'Audio features',
              _buildFeaturesCard(theme),
            ),
          ),
      ];

      return _buildCenteredScrollable(
        tab: 0,
        availableWidth: width,
        isWide: isWide,
        maxWidth: is2Pane ? 1000 : 580,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        deviceHero: _buildDeviceHero(theme),
        children: [
          if (is2Pane)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0) const SizedBox(width: 24),
                  Expanded(child: sections[i]),
                ],
              ],
            )
          else
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: 24),
              sections[i],
            ],
          const SizedBox(height: 24),
          _buildEqualizerSection(theme, wide: is2Pane),
          if (hasTimer) ...[
            const SizedBox(height: 24),
            _disconnectedPreview(_buildAutoShutdownSection(theme)),
          ],
        ],
      );
    });
  }

  Widget _buildControlSection(ThemeData theme, String heading, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader(theme, heading),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _buildDeviceHero(ThemeData theme) {
    const artworkSize = 276.0;
    final defaultVariant = theme.brightness == Brightness.dark
        ? 'black'
        : 'white';
    final model = _status.modelInfo;
    final variant = _isConnected && model?['key'] == 'FREEBUDS_5I'
        ? switch (model?['sub_model_id']?.toString().toUpperCase()) {
            // AI Life audio plugin resource maps for 00013D and 000145.
            '01' => 'white',
            '07' => 'blue',
            '0C' => 'black',
            _ => defaultVariant,
          }
        : defaultVariant;
    final title = _isConnected ? _deviceName : 'Disconnected';
    return Column(
      children: [
        Align(
          widthFactor: 1,
          heightFactor: 0.865,
          child: Image.asset(
            'assets/images/devices/freebuds_5i_$variant.png',
            width: artworkSize,
            height: artworkSize,
            cacheWidth: (artworkSize * MediaQuery.devicePixelRatioOf(context))
                .round(),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            excludeFromSemantics: true,
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: _motionDuration(140),
          child: Text(
            title,
            key: ValueKey(title),
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 10),
        _buildStatusCluster(theme),
      ],
    );
  }

  Widget _buildConnectionAction(ThemeData theme) {
    final colors = theme.colorScheme;
    return FilledButton.icon(
      onPressed: _isConnected
          ? _confirmDisconnect
          : _isConnecting
          ? null
          : _connectDevice,
      icon: Icon(
        _isConnected ? Icons.bluetooth_disabled : Icons.bluetooth_searching,
      ),
      label: IndexedStack(
        index: _isConnected ? 2 : (_isConnecting ? 1 : 0),
        alignment: Alignment.center,
        children: const [
          Text('Connect device'),
          Text('Connecting…'),
          Text('Disconnect earbuds'),
        ],
      ),
      style: FilledButton.styleFrom(
        backgroundColor: colors.surfaceContainerHigh.withValues(alpha: 0.5),
        disabledBackgroundColor: colors.surfaceContainerHigh.withValues(
          alpha: 0.5,
        ),
        disabledForegroundColor: colors.onSurface,
        disabledIconColor: colors.primary,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: colors.onSurface,
        iconColor: colors.primary,
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.3)),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ).copyWith(elevation: const WidgetStatePropertyAll(0)),
    );
  }

  Widget _buildStatusCluster(ThemeData theme) {
    final List<Widget> batteryBadges = [];
    final labelStyle = theme.textTheme.labelMedium!;
    final textSize = labelStyle.fontSize!;
    final scaledSize = MediaQuery.textScalerOf(context).scale(textSize);
    final lineHeight = (scaledSize * (labelStyle.height ?? 1.4)).ceilToDouble();


    Widget buildBatteryPill({
      required Widget icon,
      required String label,
      required int? percent,
    }) {
      final isLow = percent != null && percent <= 20;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isLow
              ? theme.colorScheme.errorContainer.withOpacity(0.5)
              : theme.colorScheme.surfaceContainerHigh.withOpacity(0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isLow
                ? theme.colorScheme.error.withOpacity(0.3)
                : theme.colorScheme.outlineVariant.withOpacity(0.3),
            width: 1,
          ),
        ),
        child: SizedBox(
          height: lineHeight < 16 ? 16 : lineHeight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme.merge(
                  data: IconThemeData(
                    size: 16,
                    color: isLow
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  child: icon,
                ),
                const SizedBox(width: 5),
                Text.rich(
                  TextSpan(
                    children: [
                      if (label.isNotEmpty)
                        TextSpan(
                          text: '$label ',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      TextSpan(text: '${percent ?? 0}%'),
                    ],
                  ),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isLow
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_isAndroid || _status.isTws || _status.deviceModel.hasTwsBattery) {
      batteryBadges.addAll([
        buildBatteryPill(
          icon: const EarbudBatteryIcon(EarbudBatteryPart.left),
          label: 'L',
          percent: _status.batteryLeft,
        ),
        buildBatteryPill(
          icon: const EarbudBatteryIcon(EarbudBatteryPart.chargingCase),
          label: 'Case',
          percent: _status.batteryCase,
        ),
        buildBatteryPill(
          icon: const EarbudBatteryIcon(EarbudBatteryPart.right),
          label: 'R',
          percent: _status.batteryRight,
        ),
      ]);
    } else {
      batteryBadges.add(
        buildBatteryPill(
          icon: Icon(
            _batteryPercent <= 20
                ? Icons.battery_alert_rounded
                : Icons.battery_full_rounded,
          ),
          label: '',
          percent: _batteryPercent,
        ),
      );
    }

    final width = 300 * scaledSize / textSize;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BatteryReveal(
            duration: _motionDuration(320),
            badges: !_isConnected
                ? null
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    spacing: 8,
                    children: [
                      for (var i = 0; i < batteryBadges.length; i++)
                        if (batteryBadges.length == 1)
                          Flexible(child: batteryBadges[i])
                        else
                          Expanded(
                            flex: i == 1 ? 4 : 3,
                            child: batteryBadges[i],
                          ),
                    ],
                  ),
          ),
          _buildConnectionAction(theme),
        ],
      ),
    );
  }

  Widget _buildNoiseControls(ThemeData theme) {
    final canExpand =
        _isConnected &&
        _status.hasAncLevels &&
        (_selectedAncMode == 'ANC On' || _selectedAncMode == 'Adaptive');
    final expanded = canExpand && _ancLevelExpanded;
    final colors = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: _buildSectionHeader(theme, 'Noise control')),
            Visibility(
              visible: canExpand,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: IconButton.filledTonal(
                tooltip: expanded
                    ? 'Hide noise cancellation levels'
                    : 'Show noise cancellation levels',
                isSelected: expanded,
                style: IconButton.styleFrom(
                  backgroundColor: colors.surfaceContainerLow,
                  foregroundColor: colors.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
                icon: AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: _motionDuration(180),
                  curve: Curves.easeOutCubic,
                  child: const Icon(Icons.keyboard_arrow_down_rounded),
                ),
                onPressed: () => setState(() => _ancLevelExpanded = !expanded),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AncSelector(
          selectedMode: _selectedAncMode,
          enabled: _isConnected,
          showAdaptive: !widget.headphoneController.hasFreeBudsControls ||
              _status.modelInfo?['adaptive_anc'] == true ||
              _selectedAncMode == 'Adaptive',
          onChanged: _handleAncModeChanged,
        ),
        _animateSize(
          expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('ANC level', style: theme.textTheme.labelLarge),
                          const SizedBox(height: 4),
                          SegmentedButton<int>(
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: const [
                              ButtonSegment(value: 2, label: Text('Low')),
                              ButtonSegment(value: 1, label: Text('Medium')),
                              ButtonSegment(value: 0, label: Text('High')),
                            ],
                            selected: {_selectedAncIntensity},
                            onSelectionChanged: (selection) =>
                                _handleAncIntensityChanged(selection.first),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildDeviceTab(ThemeData theme, {required bool isWide}) {
    return _widthLayout(
      (width) => _buildCenteredScrollable(
        tab: 1,
        availableWidth: width,
        isWide: isWide,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [_disconnectedPreview(_buildDeviceSettingsCard(theme))],
      ),
    );
  }

  Widget _buildEqualizerSection(ThemeData theme, {required bool wide}) {
    if (!_isConnected ||
        _status.modelInfo == null ||
        widget.headphoneController.hasFreeBudsControls) {
      return _buildFreeBudsEqualizer(theme);
    }

    return _buildControlSection(
      theme,
      'Equalizer',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          EqSelector(
            selectedPreset: _selectedEqPreset,
            presets: _status.eqType == 's40'
                ? EqSelector.defaultS40Presets
                : EqSelector.standardPresets,
            enabled: true,
            onChanged: _handleEqPresetChanged,
          ),
          _buildCustomEqCard(theme, isDesktop: wide),
          _buildCustomPresetsCard(theme),
        ],
      ),
    );
  }

  Widget _buildFreeBudsEqualizer(ThemeData theme) {
    final reported = _isConnected ? (_status.modelInfo?['eq_modes']) : null;
    final canSelect =
        _isConnected &&
        widget.headphoneController.hasFreeBudsControls &&
        !_inFlightControls.contains('eq_preset');
    final available = {
      for (final entry in freeBudsEqPresets.entries)
        if (reported is! List || reported.contains(entry.key))
          entry.key: entry.value,
    };
    return _buildControlSection(
      theme,
      'Sound presets',
      available.isEmpty
          ? const Text('Sound presets are unavailable on these earbuds')
          : SegmentedButton<int>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              expandedInsets: EdgeInsets.zero,
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? null
                      : theme.colorScheme.surfaceContainerLow,
                ),
                visualDensity: VisualDensity.compact,
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                ),
              ),
              segments: [
                for (final entry in available.entries)
                  ButtonSegment(
                    value: entry.key,
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(entry.value),
                    ),
                  ),
              ],
              selected: {
                for (final entry in available.entries)
                  if (_isConnected && _selectedEqPreset == entry.value)
                    entry.key,
              },
              onSelectionChanged: !_isConnected
                  ? (_) => _connectDevice()
                  : canSelect
                  ? (selection) {
                      if (selection.isEmpty) return;
                      final mode = selection.first;
                      _executeOptimisticAction<String>(
                        controlKey: 'eq_preset',
                        controlName: 'EQ preset',
                        newValue: available[mode]!,
                        currentValue: _selectedEqPreset,
                        timeout: null,
                        action: () async {
                          await widget.headphoneController.runFreeBudsCommand(
                            FreeBudsCommand.eq,
                            {'mode': mode},
                          );
                        },
                      );
                    }
                  : null,
            ),
    );
  }

  Widget _buildCustomPresetsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    'My custom presets',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_customPresets.length}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_customPresets.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        Icons.tune_outlined,
                        size: 32,
                        color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No custom presets saved yet',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _customPresets.map((preset) {
                  final name = preset['name'] as String;
                  final values = preset['values'] as List<double>;

                  bool isMatch = true;
                  for (int i = 0; i < 10; i++) {
                    if ((_eqValues[i] - values[i]).abs() > 0.01) {
                      isMatch = false;
                      break;
                    }
                  }

                  return InputChip(
                    label: Text(name),
                    selected: isMatch,
                    showCheckmark: false,
                    onSelected: _isConnected
                        ? (selected) {
                            setState(() {
                              for (int i = 0; i < 10; i++) {
                                _eqValues[i] = values[i];
                              }
                            });
                            widget.headphoneController.setCustomEq(_eqValues);
                          }
                        : null,
                    onDeleted: _isConnected
                        ? () => _showDeletePresetDialog(preset)
                        : null,
                    deleteIcon: const Icon(Icons.close, size: 16),
                    tooltip: 'Select $name',
                  );
                }).toList(),
              ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _isConnected ? _showSavePresetDialog : null,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Save current preset'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomEqCard(ThemeData theme, {bool isDesktop = false}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    '10-band graphic EQ',
                    style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: _isConnected ? _showSavePresetDialog : null,
                      icon: const Icon(Icons.save),
                      tooltip: 'Save custom preset',
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      onPressed: _isConnected
                          ? () {
                              setState(() {
                                _eqValues.fillRange(0, _eqValues.length, 0.0);
                              });
                              widget.headphoneController.setEqPreset(0);
                            }
                          : null,
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Reset EQ sliders',
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Premium EQ curve visualizer
            Container(
              height: 110,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.3),
                borderRadius: BorderRadius.circular(16),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: CustomPaint(
                  painter: _EqCurvePainter(
                    values: _eqValues,
                    primaryColor: theme.colorScheme.primary,
                    gridColor: theme.colorScheme.onSurfaceVariant.withOpacity(0.08),
                  ),
                ),
              ),
            ),
            if (isDesktop) ...[
              const SizedBox(height: 20),
              _buildEqSlidersRow(theme),
            ] else ...[
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _showEqSliders
                    ? Column(
                        children: [
                          const SizedBox(height: 20),
                          _buildEqSlidersRow(theme),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 4),
              Center(
                child: IconButton(
                  onPressed: _isConnected
                      ? () {
                          setState(() {
                            _showEqSliders = !_showEqSliders;
                          });
                        }
                      : null,
                  icon: Icon(
                    _showEqSliders ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 26,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  tooltip: _showEqSliders ? 'Collapse sliders' : 'Expand sliders',
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEqSlidersRow(ThemeData theme) {
    return SizedBox(
      height: 220,
      child: Row(
        children: List.generate(_eqValues.length, (index) {
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2.0),
              child: Column(
                children: [
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: theme.sliderTheme.copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                          activeTrackColor: theme.colorScheme.primary,
                          inactiveTrackColor: theme.colorScheme.surfaceContainerHighest,
                          thumbColor: theme.colorScheme.primary,
                          overlayColor: theme.colorScheme.primary.withOpacity(0.12),
                        ),
                        child: Slider(
                          value: _eqValues[index],
                          min: -12,
                          max: 12,
                          divisions: 24,
                          onChanged: _isConnected
                              ? (val) {
                                  setState(() {
                                    _eqValues[index] = val;
                                  });
                                }
                              : null,
                          onChangeEnd: _isConnected
                              ? (val) {
                                  widget.headphoneController.setCustomEq(_eqValues);
                                }
                              : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_eqValues[index].round() > 0 ? "+" : ""}${_eqValues[index].round()}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _eqValues[index] != 0.0 ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _eqBands[index],
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Future<void> _openRepository() async {
    try {
      if (await launchUrl(
        Uri.parse('https://github.com/majaahh/aira'),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on PlatformException {
      // A browser may be unavailable on this device.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn’t open the repository link.')),
      );
    }
  }

  // --- SETTINGS TAB ---
  Widget _buildSettingsTab(ThemeData theme, {required bool isWide}) {
    return _widthLayout(
      (width) => _buildCenteredScrollable(
        tab: 2,
        availableWidth: width,
        isWide: isWide,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 32),
        children: [
          _buildControlSection(
            theme,
            'Appearance',
            _buildAppearanceCard(theme),
          ),
          if (defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.windows) ...[
            const SizedBox(height: 24),
            ExpressiveListGroup(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.picture_in_picture_alt_outlined),
                  title: const Text('Minimize to tray'),
                  subtitle: const Text(
                    'Keep running in the system tray when closing the window',
                  ),
                  value: widget.themeController.minimizeToTray,
                  onChanged: widget.themeController.setMinimizeToTray,
                ),
              ],
            ),
          ],
          if (widget.themeController.isDeveloperMode) ...[
            const SizedBox(height: 24),
            _buildControlSection(
              theme,
              'Developer settings',
              _buildSimulatorCard(theme),
            ),
          ],
          const SizedBox(height: 24),
          _buildControlSection(theme, 'About', _buildAboutCard(theme)),
        ],
      ),
    );
  }

  Widget _buildDeviceSettingsCard(ThemeData theme) {
    final freeBuds =
        _isConnected && widget.headphoneController.hasFreeBudsControls;
    final showFreeBuds = !_isConnected || _status.modelInfo == null || freeBuds;
    final showFitOption =
        _isAndroid || defaultTargetPlatform == TargetPlatform.linux;
    final canEditGestures = _isConnected && _status.hasGestures;
    final gestureStatus = switch (canEditGestures) {
      true => 'Customize double tap, triple tap, and long press',
      false when _isAndroid && _status.modelInfo == null =>
        'Checking gesture support…',
      false => 'Unavailable on this device',
    };
    return ExpressiveListGroup(
      children: [
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Rename earbuds'),
          subtitle: Text(_isConnected ? _deviceName : 'Disconnected'),
          trailing: const Icon(Icons.chevron_right),
          enabled: _isConnected,
          onTap: _isConnected ? _showRenameDialog : null,
        ),
        if (showFreeBuds)
          for (final (page, icon, description) in [
            (
              FreeBudsPage.gestures,
              Icons.touch_app_outlined,
              'Tap, swipe, call actions, and noise control cycles',
            ),
            (FreeBudsPage.locator, Icons.search, 'Ring either earbud'),
            (
              FreeBudsPage.preferences,
              Icons.tune,
              showFitOption
                  ? 'Voice prompts, audio options, and ear tip fit'
                  : 'Voice prompts and audio options',
            ),
            (
              FreeBudsPage.information,
              Icons.info_outline,
              'Model, firmware, and serial numbers',
            ),
          ]) ...[
            ListTile(
              leading: Icon(icon),
              title: Text(page.title),
              subtitle: Text(description),
              trailing: const Icon(Icons.chevron_right),
              enabled: freeBuds,
              onTap: freeBuds ? () => _openFreeBudsSettings(page) : null,
            ),
          ]
        else ...[
          ListTile(
            leading: const Icon(Icons.touch_app_outlined),
            title: const Text('Touch gestures'),
            subtitle: Text(gestureStatus),
            trailing: canEditGestures ? const Icon(Icons.chevron_right) : null,
            enabled: canEditGestures,
            onTap: canEditGestures ? _showGestureConfigDialog : null,
          ),
          ListTile(
            leading: Icon(_isFindingDevice ? Icons.volume_up : Icons.search),
            title: const Text('Find my earbuds'),
            subtitle: Text(
              _isFindingDevice
                  ? 'Ringing active — tap to stop'
                  : 'Play sound tone to locate headphones',
            ),
            trailing: _isFindingDevice
                ? FilledButton.tonal(
                    onPressed: _toggleFindDevice,
                    child: const Text('Stop'),
                  )
                : OutlinedButton(
                    onPressed: _toggleFindDevice,
                    child: const Text('Ring'),
                  ),
            onTap: _toggleFindDevice,
          ),
        ],
      ],
    );
  }

  Future<void> _openFreeBudsSettings(FreeBudsPage page) async {
    if (page == FreeBudsPage.locator) {
      if (_checkingLocator) return;
      _checkingLocator = true;
      try {
        final wear = await widget.headphoneController.runFreeBudsCommand(
          FreeBudsCommand.controls,
          {'section': 'wear'},
        );
        if (!mounted || !_isConnected) return;
        if (wear['left_in'] != false || wear['right_in'] != false) {
          _showLocatorMessage(worn: wear['left_in'] == true || wear['right_in'] == true);
          return;
        }
      } catch (_) {
        if (mounted && _isConnected) {
          _showLocatorMessage(worn: false);
        }
        return;
      } finally {
        _checkingLocator = false;
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FreeBudsSettingsScreen(
          controller: widget.headphoneController,
          page: page,
        ),
      ),
    );
  }

  void _showLocatorMessage({required bool worn}) {
    showEarbudLocatorNotice(
      context,
      worn
          ? 'The earbuds play a loud sound when they ring. Take both out first.'
          : 'Check that both earbuds are out of your ears, then try again.',
      title: worn ? 'Remove your earbuds' : 'Couldn’t check wear status',
    );
  }

  Widget _buildAppearanceCard(ThemeData theme) {
    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.palette_outlined,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Theme mode',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_outlined, size: 18),
                        label: Text('System'),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined, size: 18),
                        label: Text('Light'),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined, size: 18),
                        label: Text('Dark'),
                      ),
                    ],
                    selected: {widget.themeController.themeMode},
                    onSelectionChanged: (modes) {
                      widget.themeController.setThemeMode(modes.first);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutCard(ThemeData theme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () {
              if (!widget.themeController.isDeveloperMode) {
                setState(() {
                  _buildTapCount++;
                  if (_buildTapCount >= 5) {
                    widget.themeController.setDeveloperMode(true);
                    _buildTapCount = 0;
                    ScaffoldMessenger.of(context).clearSnackBars();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Developer settings unlocked! 🎉'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  }
                });
              }
            },
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.headphones,
                      color: theme.colorScheme.onPrimaryContainer,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aira',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          buildCommit,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(
            height: 1,
            color: theme.colorScheme.outlineVariant.withOpacity(0.35),
            indent: 16,
            endIndent: 16,
          ),
          ListTile(
            leading: const Icon(Icons.code_rounded),
            title: const Text('Repository'),
            subtitle: const Text('GitHub source code and issue tracker'),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: _openRepository,
          ),
        ],
      ),
    );
  }

  Widget _buildSimulatorCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(child: Text('Mock headphone connection')),
                Switch(
                  value: _isConnected,
                  onChanged: (val) {
                    widget.themeController.setMockConnected(val);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Simulate earbuds model'),
            const SizedBox(height: 6),
            Builder(
              builder: (fieldContext) {
                final selectedKey = widget.themeController.mockDeviceKey;
                final models = {
                  for (final profile in mockModelProfiles)
                    profile.key: profile.displayName,
                };

                return InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () async {
                    final key = await showExpressiveMenu<String>(
                      context: fieldContext,
                      preferredHeight: 312,
                      builder: (context) => ExpressiveActionMenu(
                        actions: models,
                        selectedValue: selectedKey,
                      ),
                    );
                    if (fieldContext.mounted && key != null) {
                      widget.themeController.setMockDeviceKey(key);
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    child: Row(
                      children: [
                        Expanded(child: Text(models[selectedKey] ?? '')),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            const Text('Simulate battery percentage'),
            Slider(
              value: _batteryPercent.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              label: '$_batteryPercent%',
              onChanged: _isConnected
                  ? (val) {
                      widget.themeController.setMockBatteryPercent(val.toInt());
                    }
                  : null,
            ),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _buildTapCount = 0;
                });
                widget.themeController.setDeveloperMode(false);
                widget.themeController.setMockConnected(false);
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Developer options disabled.'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              icon: const Icon(Icons.developer_mode),
              label: const Text('Disable developer mode'),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error.withOpacity(0.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- GENERAL WIDGETS ---

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Text(
      title,
      style: theme.textTheme.titleSmall,
    );
  }

  Widget _buildAutoShutdownSection(ThemeData theme) {
    if (!_isAndroid) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionHeader(theme, 'Auto shutdown'),
          const SizedBox(height: 12),
          _buildAutoShutdownCard(theme),
        ],
      );
    }

    final inFlight = _inFlightControls.contains('auto_shutdown');
    final controller = widget.headphoneController;
    final software = controller.usesSoftwareShutdown;
    final softwareTimer = controller.softwareShutdown;
    final seconds = software
        ? softwareTimer?.seconds ?? 0
        : _status.autoShutdownSeconds;
    final minutes = (seconds ?? 0) ~/ 60;
    final remainder = (seconds ?? 0) % 60;
    final delay = [
      if (minutes > 0) '$minutes min',
      if (remainder > 0) '$remainder sec',
    ].join(' ');
    final message = switch (seconds) {
      _ when !_isConnected && controller.softwareBluetoothDisconnectFailed =>
        'Aira disconnected. Bluetooth audio may still be connected.',
      _ when !_isConnected => null,
      _ when software => null,
      _ when _status.modelInfo == null && !_status.hasAutoShutdown =>
        'Checking timer support…',
      _ when !_status.hasAutoShutdown => 'Unavailable on this device',
      null => 'Current timer unknown',
      0 => 'Off',
      _ => 'After $delay of inactivity',
    };

    return _buildControlSection(
      theme,
      'Auto shutdown',
      ShutdownTimerCard(
        key: ValueKey((
          widget.themeController.lastConnectedMac,
          widget.themeController.isMockConnected,
        )),
        seconds: seconds,
        status: inFlight ? 'Updating timer…' : message,
        deadline: softwareTimer?.deadline,
        initialInput: widget.themeController.shutdownTimerInput,
        enabled: _isConnected && (_status.hasAutoShutdown || software),
        allowRestart: software,
        saving: inFlight,
        onChanged: _setAutoShutdownSeconds,
      ),
    );
  }

  Widget _buildAutoShutdownCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Shut down when idle',
                  style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  _shutdownOptions[_autoShutdownIndex],
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Slider(
              value: _autoShutdownIndex.toDouble(),
              min: 0,
              max: 4,
              divisions: 4,
              onChanged: _isConnected
                  ? (val) => _handleAutoShutdownChanged(val.toInt())
                  : null,
            ),
            // Mathematically aligned labels using Stack layout
            LayoutBuilder(
              builder: (context, constraints) {
                final double width = constraints.maxWidth;
                const double trackPadding = 24.0; // Margin at each end of the Slider track
                final double trackWidth = width - 2 * trackPadding;

                return SizedBox(
                  height: 20,
                  child: Stack(
                    children: List.generate(_shutdownTickLabels.length, (index) {
                      final String labelText = _shutdownTickLabels[index];
                      final double tickX = trackPadding + index * (trackWidth / 4);

                      return Positioned(
                        left: tickX - 30, // Center the 60px wide label on the tick mark
                        width: 60,
                        child: Text(
                          labelText,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
                          ),
                        ),
                      );
                    }),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeaturesCard(ThemeData theme) {
    final status = widget.headphoneController.status;
    final List<Widget> children = [];

    void addDividerIfNotEmpty() {
      if (children.isNotEmpty) {
        children.add(const Divider(height: 1, indent: 16, endIndent: 16));
      }
    }

    // Game Mode
    if (status.gameMode != null || !_isConnected) {
      addDividerIfNotEmpty();
      children.add(SwitchListTile(
        secondary: const Icon(Icons.sports_esports),
        title: const Text('Game mode'),
        subtitle: const Text('Low-latency audio channel'),
        value: _gameMode,
        onChanged: _isConnected ? _handleGameModeChanged : null,
      ));
    }

    // Wind Noise Reduction
    if (status.hasAnc && (status.windNoise != null || !_isConnected)) {
      addDividerIfNotEmpty();
      children.add(SwitchListTile(
        secondary: const Icon(Icons.air),
        title: const Text('Wind noise reduction'),
        subtitle: const Text('Filters out outdoor wind noise'),
        value: _windNoiseReduction,
        onChanged: _isConnected ? _handleWindNoiseChanged : null,
      ));
    }

    // Multipoint Connection
    if (status.multipoint != null || !_isConnected) {
      addDividerIfNotEmpty();
      children.add(SwitchListTile(
        secondary: const Icon(Icons.link),
        title: const Text('Multipoint connection'),
        subtitle: const Text('Dual simultaneous device connections'),
        value: _multipoint,
        onChanged: _isConnected ? _handleMultipointChanged : null,
      ));
    }

    // LDAC High-Resolution Audio
    if (status.hasLdac) {
      addDividerIfNotEmpty();
      children.add(SwitchListTile(
        secondary: const Icon(Icons.high_quality),
        title: const Text('LDAC high-resolution audio'),
        subtitle: const Text('High-definition Bluetooth audio codec'),
        value: _ldac,
        onChanged: _isConnected ? _handleLdacChanged : null,
      ));
    }

    // Smart Wear Detection
    if (status.hasWearDetection) {
      addDividerIfNotEmpty();
      children.add(SwitchListTile(
        secondary: const Icon(Icons.hearing),
        title: const Text('Smart wear detection'),
        subtitle: const Text('Auto-pause audio on removal'),
        value: _wearDetection,
        onChanged: _isConnected ? _handleWearDetectionChanged : null,
      ));
    }

    // Anti-Sound Leak (BC04 Purfree Lite)
    if (status.hasAntiLeak) {
      addDividerIfNotEmpty();
      children.add(SwitchListTile(
        secondary: const Icon(Icons.volume_off),
        title: const Text('Anti-sound leak'),
        subtitle: const Text('Reduces audio leakage in open-ear mode'),
        value: _antiLeak,
        onChanged: _isConnected ? _handleAntiLeakChanged : null,
      ));
    }

    // Spatial Audio (S40)
    if (status.hasSpatialAudio) {
      addDividerIfNotEmpty();
      children.add(_buildSpatialAudioTile(theme));
    }

    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Column(
        children: children,
      ),
    );
  }

  Widget _buildSpatialAudioTile(ThemeData theme) {
    final spatialModeOptions = ['Off', 'Static', 'Dynamic'];
    final spatialSceneOptions = ['Music', 'Sport', 'Movie'];

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.spatial_audio),
          title: const Text('Spatial audio'),
          subtitle: const Text('Surround sound mode selection'),
          enabled: _isConnected,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
              segments: spatialModeOptions.map((mode) {
                return ButtonSegment<String>(
                  value: mode,
                  label: Text(mode),
                );
              }).toList(),
              selected: {_spatialAudioMode},
              onSelectionChanged: _isConnected
                  ? (newSelection) {
                      _handleSpatialAudioChanged(newSelection.first);
                    }
                  : null,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOutCubic,
          child: (_isConnected && _spatialAudioMode != 'Off')
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Spatial preset scene',
                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<String>(
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: spatialSceneOptions.map((scene) {
                                return ButtonSegment<String>(
                                  value: scene,
                                  label: Text(scene),
                                );
                              }).toList(),
                              selected: {_spatialScene},
                              onSelectionChanged: _isConnected
                                  ? (newSelection) {
                                      _handleSpatialSceneChanged(newSelection.first);
                                    }
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

// Custom painter to draw a smooth curve representing the 10-band EQ
class _EqCurvePainter extends CustomPainter {
  _EqCurvePainter({
    required this.values,
    required this.primaryColor,
    required this.gridColor,
  });

  final List<double> values;
  final Color primaryColor;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final points = <Offset>[];

    final paintCurve = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final paintArea = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [primaryColor.withOpacity(0.2), primaryColor.withOpacity(0.0)],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;

    // Draw horizontal mid gridline
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, h / 2), Offset(w, h / 2), gridPaint);

    // Draw horizontal top & bottom reference lines
    canvas.drawLine(Offset(0, h * 0.1), Offset(w, h * 0.1), gridPaint);
    canvas.drawLine(Offset(0, h * 0.9), Offset(w, h * 0.9), gridPaint);

    final step = w / (values.length - 1);
    for (int i = 0; i < values.length; i++) {
      // Maps slider value [-12, 12] to screen coordinates [h*0.9, h*0.1]
      final mappedY = (h / 2) - (values[i] / 24) * (h * 0.8);
      points.add(Offset(i * step, mappedY));

      // Draw grid vertical markers
      canvas.drawLine(Offset(i * step, 0), Offset(i * step, h), gridPaint);
    }

    // Generate smooth bezier curve path
    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final controlX1 = p0.dx + (p1.dx - p0.dx) / 2;
      final controlY1 = p0.dy;
      final controlX2 = p0.dx + (p1.dx - p0.dx) / 2;
      final controlY2 = p1.dy;

      path.cubicTo(controlX1, controlY1, controlX2, controlY2, p1.dx, p1.dy);
    }

    // Draw filled shadow under the curve
    final fillPath = Path.from(path)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    canvas.drawPath(fillPath, paintArea);
    canvas.drawPath(path, paintCurve);
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.gridColor != gridColor;
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.selectedIndex,
    required this.isExpanded,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int index;
  final int selectedIndex;
  final bool isExpanded;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = widget.selectedIndex == widget.index;

    Color? backgroundColor;
    if (isSelected) {
      backgroundColor = theme.colorScheme.secondaryContainer;
    } else if (_isHovered) {
      backgroundColor = theme.colorScheme.onSurface.withOpacity(0.08);
    } else {
      backgroundColor = Colors.transparent;
    }

    final foregroundColor = isSelected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;

    final textColor = isSelected
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurface;

    if (widget.isExpanded) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(28),
              hoverColor: Colors.transparent,
              highlightColor: theme.colorScheme.secondaryContainer.withOpacity(0.24),
              splashColor: theme.colorScheme.onSecondaryContainer.withOpacity(0.12),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  color: backgroundColor,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Center(
                        child: Icon(
                          widget.icon,
                          color: foregroundColor,
                          size: 22,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                          color: textColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Tooltip(
            message: widget.label,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _isHovered = true),
              onExit: (_) => setState(() => _isHovered = false),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: BorderRadius.circular(16),
                  hoverColor: Colors.transparent,
                  highlightColor: theme.colorScheme.secondaryContainer.withOpacity(0.24),
                  splashColor: theme.colorScheme.onSecondaryContainer.withOpacity(0.12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 56,
                    height: 32,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: backgroundColor,
                    ),
                    child: Center(
                      child: Icon(
                        widget.icon,
                        color: foregroundColor,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
  }
}

class _DeviceSelectionDialog extends StatefulWidget {
  final HeadphoneController headphoneController;

  const _DeviceSelectionDialog({required this.headphoneController});

  @override
  State<_DeviceSelectionDialog> createState() => _DeviceSelectionDialogState();
}

class _DeviceSelectionDialogState extends State<_DeviceSelectionDialog> {
  bool _loading = false;
  List<BluetoothDevice> _connected = [];
  List<BluetoothDevice> _devices = [];
  String? _error;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final controller = widget.headphoneController;
      final connected = _isAndroid
          ? await controller.getConnectedBluetoothDevices()
          : const <BluetoothDevice>[];
      if (!mounted) return;
      setState(() => _connected = connected);

      final paired = await controller.getPairedDevices();
      if (!mounted) return;
      final seen = connected
          .map((device) => device.macAddress.toUpperCase())
          .toSet();
      setState(
        () => _devices = [
          for (final device in paired)
            if (seen.add(device.macAddress.toUpperCase())) device,
        ],
      );

      if (!_isAndroid) {
        final nearby = await controller.scanDevices();
        if (!mounted) return;
        setState(
          () => _devices = [
            ..._devices,
            for (final device in nearby)
              if (seen.add(device.macAddress.toUpperCase())) device,
          ],
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget deviceRow(BluetoothDevice device, {required bool connected}) {
      final name = widget.headphoneController.themeController.getDeviceName(
        device.macAddress,
        device.name,
      );
      return ListTile(
        leading: Icon(connected ? Icons.bluetooth_connected : Icons.bluetooth),
        title: Text(name.isEmpty ? device.macAddress : name),
        subtitle: name.isEmpty ? null : Text(device.macAddress),
        onTap: () => Navigator.pop(context, device),
      );
    }

    Widget heading(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Text(title, style: theme.textTheme.labelLarge),
    );

    final empty = _connected.isEmpty && _devices.isEmpty;
    return AlertDialog(
      title: const Text('Connect earbuds'),
      content: SizedBox(
        width: 400,
        height: 350,
        child: empty && (_loading || _error != null)
            ? Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : Text(_error!, textAlign: TextAlign.center),
              )
            : ListView(
                children: [
                  if (_connected.isNotEmpty) ...[
                    heading('Connected to Bluetooth'),
                    ExpressiveListGroup(
                      children: [
                        for (final device in _connected)
                          deviceRow(device, connected: true),
                      ],
                    ),
                  ],
                  if (_devices.isNotEmpty) ...[
                    if (_connected.isNotEmpty) const SizedBox(height: 14),
                    heading(
                      _isAndroid ? 'Paired devices' : 'Available devices',
                    ),
                    ExpressiveListGroup(
                      children: [
                        for (final device in _devices)
                          deviceRow(device, connected: false),
                      ],
                    ),
                  ],
                  if (empty)
                    Text(
                      _isAndroid
                          ? 'No connected or paired earbuds.'
                          : 'No devices found nearby.',
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _loadDevices,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _BatteryReveal extends StatefulWidget {
  const _BatteryReveal({required this.badges, required this.duration});

  final Widget? badges;
  final Duration duration;

  @override
  State<_BatteryReveal> createState() => _BatteryRevealState();
}

class _BatteryRevealState extends State<_BatteryReveal>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.badges == null ? 0 : 1,
  );
  late final _extent = _controller.drive(CurveTween(curve: Curves.easeInOut));
  late Widget? _lastBadges = widget.badges;

  @override
  void didUpdateWidget(_BatteryReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    _lastBadges = widget.badges ?? _lastBadges;
    final visible = widget.badges != null;
    if (widget.duration == Duration.zero) {
      _controller.value = visible ? 1 : 0;
    } else if (visible != (oldWidget.badges != null)) {
      if (visible) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _extent,
    child: FadeTransition(
      opacity: _extent,
      child: ExcludeSemantics(
        excluding: widget.badges == null,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: RepaintBoundary(child: _lastBadges),
        ),
      ),
    ),
    builder: (context, row) {
      if (_controller.isDismissed) return const SizedBox.shrink();
      return ClipRect(
        child: Align(
          alignment: Alignment.center,
          heightFactor: _extent.value,
          child: row,
        ),
      );
    },
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
