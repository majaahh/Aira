import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/controllers/headphone_controller.dart';
import '../../core/services/freebuds_service.dart';
import '../widgets/expressive_popup.dart';

enum FreeBudsPage {
  gestures('Touch gestures', 'gestures'),
  locator('Find my earbuds', 'locator'),
  preferences('Earbud preferences', 'preferences'),
  information('Earbud information', 'information');

  const FreeBudsPage(this.title, this.section);

  final String title;
  final String section;
}

class FreeBudsSettingsScreen extends StatefulWidget {
  const FreeBudsSettingsScreen({
    super.key,
    required this.controller,
    required this.page,
  });

  final HeadphoneController controller;
  final FreeBudsPage page;

  @override
  State<FreeBudsSettingsScreen> createState() => _FreeBudsSettingsScreenState();
}

class _FreeBudsSettingsScreenState extends State<FreeBudsSettingsScreen> {
  static final _titleBlur = ImageFilter.blur(sigmaX: 16, sigmaY: 16);
  static const _earNames = {'left': 'Left', 'right': 'Right'};
  static const _gestureNames = {
    'double_click': 'Double tap',
    'triple_click': 'Triple tap',
    'long_press': 'Long press',
    'slide': 'Swipe',
  };
  static const _actions = {
    'double_click': {
      0: 'Voice assistant',
      1: 'Play / Pause',
      2: 'Next track',
      7: 'Previous track',
      255: 'None',
    },
    'triple_click': {2: 'Next track', 7: 'Previous track', 255: 'None'},
    'long_press': {
      10: 'Noise control',
      14: 'Song recognition',
      15: 'Freestyle listen',
      255: 'None',
    },
    'slide': {0: 'Volume', 255: 'None'},
  };
  static const _cycles = {
    1: 'Noise cancelling / Off',
    2: 'Noise cancelling / Off / Awareness',
    3: 'Noise cancelling / Awareness',
    4: 'Off / Awareness',
  };
  static const _features = {
    'venh': 'Voice enhancement',
    'hd': 'Prioritize sound quality',
    'silent': 'Automatic updates',
    'health': 'Hearing health alerts',
    'greet': 'Welcome tone',
    'saving': 'Power saving',
    'volume': 'Smart volume',
    'translate': 'Translation mode',
    'hd_voice': '32 kHz voice audio',
    'ear_balance': 'Left/right ear detection',
  };

  Map<String, dynamic> _data = {};
  bool _loading = true;
  bool _busy = false;
  bool _connected = false;
  int _connectionVersion = 0;
  String? _error;
  String? _fitResult;
  String? _selectedGesture;
  final _revealedSerials = <String, String>{};
  AppLifecycleListener? _informationLifecycle;
  Timer? _informationTimer;
  bool _updatingInformation = false;

  bool get _showsLiveInformation => widget.page == FreeBudsPage.information;

  bool get _available =>
      widget.controller.isConnected && widget.controller.hasFreeBudsControls;

  @override
  void initState() {
    super.initState();
    _connected = _available;
    widget.controller.addListener(_onConnectionChanged);
    if (_showsLiveInformation) {
      _informationLifecycle = AppLifecycleListener(
        onStateChange: (state) {
          if (state == AppLifecycleState.resumed) {
            _scheduleInformationUpdate(Duration.zero);
          } else if (state != AppLifecycleState.inactive) {
            _informationTimer?.cancel();
          }
        },
      );
    }
    if (_connected) _load();
  }

  @override
  void dispose() {
    _informationTimer?.cancel();
    _informationLifecycle?.dispose();
    widget.controller.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    if (_available == _connected) return;
    _informationTimer?.cancel();
    setState(() {
      _connected = _available;
      _connectionVersion++;
      _data = {};
      _selectedGesture = null;
      _updatingInformation = false;
      _error = null;
      _fitResult = null;
      _loading = _connected;
      _busy = false;
    });
    if (_connected) _load();
  }

  Future<void> _load() async {
    if (!_connected || _updatingInformation) return;
    _informationTimer?.cancel();
    final version = _connectionVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    final command = switch (widget.page) {
      FreeBudsPage.information => FreeBudsCommand.information,
      _ => FreeBudsCommand.controls,
    };
    try {
      final result = await widget.controller.runFreeBudsCommand(command, {
        'section': widget.page.section,
      });
      if (!mounted || version != _connectionVersion) return;
      setState(() => _data = result);
    } catch (error) {
      if (!mounted || version != _connectionVersion) return;
      setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted && version == _connectionVersion) {
        setState(() => _loading = false);
        if (_showsLiveInformation) _scheduleInformationUpdate();
      }
    }
  }

  void _scheduleInformationUpdate([
    Duration delay = const Duration(seconds: 6),
  ]) {
    _informationTimer?.cancel();
    final state = WidgetsBinding.instance.lifecycleState;
    if (!_connected ||
        _loading ||
        _updatingInformation ||
        (state != null && state != AppLifecycleState.resumed)) {
      return;
    }
    _informationTimer = Timer(delay, _updateInformation);
  }

  Future<void> _updateInformation() async {
    if (!mounted || !_connected || _loading || _updatingInformation) return;
    if (ModalRoute.of(context)?.isCurrent != true) {
      _scheduleInformationUpdate();
      return;
    }
    if (_error != null && _data.isEmpty) {
      await _load();
      return;
    }
    final version = _connectionVersion;
    _updatingInformation = true;
    try {
      final result = await widget.controller.runFreeBudsCommand(
        FreeBudsCommand.information,
        {'live': true},
      );
      if (!mounted || version != _connectionVersion) return;
      setState(() {
        _data.addAll(result);
        _error = null;
      });
    } catch (error) {
      if (mounted && version == _connectionVersion) {
        setState(() => _error = _errorMessage(error));
      }
    } finally {
      if (mounted && version == _connectionVersion) {
        _updatingInformation = false;
        _scheduleInformationUpdate();
      }
    }
  }

  Future<void> _change(
    FreeBudsCommand command,
    Map<String, Object> args,
    void Function(Map<String, dynamic>) apply,
  ) async {
    if (!_connected || _busy) return;
    final version = _connectionVersion;
    setState(() => _busy = true);
    try {
      final result = await widget.controller.runFreeBudsCommand(command, args);
      if (!mounted || version != _connectionVersion) return;
      setState(() => apply(result));
    } catch (error) {
      if (!mounted || version != _connectionVersion) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
    } finally {
      if (mounted && version == _connectionVersion) {
        setState(() => _busy = false);
      }
    }
  }

  String _errorMessage(Object error) => switch (error) {
    StateError(:final message) => message,
    PlatformException(:final message) =>
      message ?? 'The earbuds did not respond',
    _ => 'The earbuds did not respond',
  };

  Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  List<T> _list<T>(Object? value) =>
      value is List ? value.whereType<T>().toList() : [];

  void _setField(String group, String key, Object? value) {
    _data[group] = {..._map(_data[group]), key: value};
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        centerTitle: false,
        leadingWidth: 60,
        titleSpacing: 12,
        leading: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: SizedBox.square(
            dimension: 40,
            child: IconButton.filledTonal(
              padding: EdgeInsets.zero,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => Navigator.maybePop(context),
              icon: const BackButtonIcon(),
            ),
          ),
        ),
        title: Text(
          widget.page.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
        backgroundColor: Colors.transparent,
        forceMaterialTransparency: true,
        notificationPredicate: (_) => false,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: _titleBlur,
            child: ColoredBox(
              color: theme.scaffoldBackgroundColor.withValues(alpha: 0.72),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        actions: [
          if (!_showsLiveInformation)
            IconButton(
              tooltip: 'Refresh',
              onPressed: _connected && !_loading && !_busy ? _load : null,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Builder(
              builder: (context) =>
                  _buildBody(MediaQuery.paddingOf(context).top),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(double topInset) {
    if (!_connected) return const Center(child: Text('Earbuds disconnected'));
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error case final error? when _data.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final children = switch (widget.page) {
      FreeBudsPage.gestures => _gestureCards(),
      FreeBudsPage.locator => _locatorCards(),
      FreeBudsPage.preferences => _preferenceCards(),
      FreeBudsPage.information => _informationCards(),
    };
    return ListView(
      padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 24),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          ListTile(title: const Text('Waiting for updated earbud information')),
        if (children.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('The earbuds did not report any available options'),
          ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 20,
          children: children,
        ),
      ],
    );
  }

  Widget _card(String? title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 3,
    children: [
      if (title != null)
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 5),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
      for (final (index, child) in children.indexed)
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(index == 0 ? 24 : 10),
              bottom: Radius.circular(index == children.length - 1 ? 24 : 10),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
    ],
  );

  Widget _option<T extends Object>(
    String title,
    T? current,
    Map<T, String> options,
    ValueChanged<T> change,
  ) {
    final version = _connectionVersion;
    return ExpressiveOptionPicker<T>(
      label: title,
      value: current,
      actions: options,
      onSelected: _busy
          ? null
          : (value) {
              if (version == _connectionVersion) change(value);
            },
    );
  }

  List<Widget> _gestureCards() {
    final gestures = _map(_data['gestures']);
    final cycle = _map(_data['cycle']);
    final cycleOptions = {
      for (final number in _list<int>(cycle['supported']))
        if (_cycles.containsKey(number)) number: _cycles[number]!,
    };
    final pages = <String, String>{
      for (final entry in _gestureNames.entries)
        if ([
          'left',
          'right',
          'global',
          'call_action',
        ].any(_map(gestures[entry.key]).containsKey))
          entry.key: entry.value,
      if (_earNames.keys.any(cycle.containsKey)) 'noise_cycle': 'Noise cycle',
    };
    if (pages.isEmpty) return [];
    final selected = pages.containsKey(_selectedGesture)
        ? _selectedGesture!
        : pages.keys.first;
    return [
      if (pages.length > 1)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            segments: [
              for (final page in pages.entries)
                ButtonSegment(value: page.key, label: Text(page.value)),
            ],
            selected: {selected},
            onSelectionChanged: _busy
                ? null
                : (value) => setState(() => _selectedGesture = value.first),
          ),
        ),
      if (selected == 'noise_cycle')
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            for (final ear in _earNames.entries)
              if (cycle[ear.key] case final int current)
                _option('${ear.value} earbud', current, cycleOptions, (value) {
                  _change(FreeBudsCommand.noiseCycle, {
                    'side': ear.key,
                    'cycle': value,
                  }, (result) => _data['cycle'] = result);
                }),
          ],
        )
      else
        _gestureCard(selected, _map(gestures[selected])),
    ];
  }

  Widget _gestureCard(String key, Map<String, dynamic> state) {
    final options = {
      for (final number in _list<int>(state['supported']))
        if (_actions[key]!.containsKey(number)) number: _actions[key]![number]!,
    };
    final callOptions = {
      for (final number in _list<int>(state['call_supported']))
        if (number == 255 || number == 0)
          number: number == 255
              ? 'None'
              : (key == 'long_press' ? 'Reject call' : 'Answer / End call'),
    };
    final sides = {
      'left': 'Left earbud',
      'right': 'Right earbud',
      'global': 'Both earbuds',
      'call_action': 'During calls',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final side in sides.entries)
          if (state[side.key] case final int current)
            _option(
              side.value,
              current,
              side.key == 'call_action' ? callOptions : options,
              (value) {
                _change(FreeBudsCommand.gesture, {
                  'key': key,
                  'side': side.key == 'call_action' ? 'call' : side.key,
                  'action': value,
                }, (result) => _setField('gestures', key, result));
              },
            ),
      ],
    );
  }

  List<Widget> _locatorCards() {
    final locator = _map(_data['locator']);
    final ears = {
      for (final ear in _earNames.entries)
        if (_map(locator[ear.key])['ringing'] case final bool ringing)
          ear.key: ringing,
    };
    if (ears.isEmpty) return [];
    return [
      _card(null, [
        const ListTile(
          subtitle: Text('Remove the earbuds before ringing them.'),
        ),
        for (final entry in ears.entries)
          ListTile(
            title: Text('${_earNames[entry.key]} earbud'),
            trailing: FilledButton.tonal(
              onPressed: _busy
                  ? null
                  : () => _change(FreeBudsCommand.locator, {
                      'side': entry.key,
                      'ring': !entry.value,
                    }, (result) => _setField('locator', entry.key, result)),
              child: Text(entry.value ? 'Stop' : 'Ring'),
            ),
          ),
      ]),
    ];
  }

  List<Widget> _preferenceCards() {
    final features = _map(_data['features']);
    final language = _map(_data['language']);
    final codes = _list<String>(language['supported'])
        .where((code) => code.isNotEmpty);
    final preferences = <Widget>[
      for (final entry in _features.entries)
        if (features[entry.key] case final bool enabled)
          SwitchListTile(
            title: Text(entry.value),
            value: enabled,
            onChanged: _busy
                ? null
                : (value) => _change(
                    FreeBudsCommand.feature,
                    {'key': entry.key, 'enabled': value},
                    (result) =>
                        _setField('features', entry.key, result['enabled']),
                  ),
          ),
      if (codes.isNotEmpty)
        _option(
          'Voice prompt language',
          language['current'] as String?,
          {
            for (final code in codes)
              code: switch (code) {
                'en-GB' => 'English (UK)',
                'zh-CN' => 'Chinese (Simplified)',
                _ => code,
              },
          },
          (code) {
            _change(FreeBudsCommand.language, {
              'code': code,
            }, (result) => _data['language'] = result);
          },
        ),
    ];
    return [
      if (preferences.isNotEmpty) _card(null, preferences),
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux)
        _card('Ear tip fit', [
          ListTile(
            subtitle: Text(
              _fitResult ?? 'Wear both earbuds and stay in a quiet room.',
            ),
            trailing: FilledButton.tonal(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _fitResult = null);
                      _change(FreeBudsCommand.fit, {}, (result) {
                        _fitResult = _earNames.entries
                            .map((ear) {
                              final fit = result[ear.key] == 'good'
                                  ? 'Good fit'
                                  : 'Adjust fit';
                              return '${ear.value}: $fit';
                            })
                            .join('\n');
                      });
                    },
              child: const Text('Run fit test'),
            ),
          ),
        ]),
    ];
  }

  List<Widget> _informationCards() {
    final version = _map(_data['version']);
    final wearing = _map(_data['wear']);
    final info = <String, Object?>{
      'Model': version['model'],
      'Firmware': version['firmware'],
      'Firmware package': version['ota_package'],
      'Bluetooth version': version['bluetooth_version'],
      'Left earbud worn': wearing['left_in'],
      'Right earbud worn': wearing['right_in'],
      'Dynamic noise cancellation': _data['dynamic'],
      'Primary Bluetooth connection': _data['btmain'],
      'Ambient sound': _data['ambient'],
      'Music mode': _data['music'],
      'Connection capability': _data['conn'],
    };
    final rows = [
      for (final entry in info.entries)
        if (entry.value case final value?)
          ListTile(
            title: Text(entry.key),
            subtitle: Text(
              value is bool ? (value ? 'Yes' : 'No') : value.toString(),
            ),
          ),
    ];
    final serials = <String, Object?>{'Charging case': version['serial']};
    if (version['bud_serials'] case final String buds) {
      final parts = RegExp(r'(?:^|,)\s*([LR])-\s*([^,]+)').allMatches(buds);
      for (final part in parts) {
        final label = part[1] == 'L' ? 'Left earbud' : 'Right earbud';
        serials[label] = part[2]?.trim();
      }
    }
    return [
      if (rows.isNotEmpty) _card(null, rows),
      _card('Serial numbers', [
        for (final label in ['Left earbud', 'Right earbud', 'Charging case'])
          _serialTile(label, serials[label]),
      ]),
    ];
  }

  Widget _serialTile(String label, Object? value) {
    final serial = value is String && value.trim().isNotEmpty ? value : null;
    final revealed = serial != null && _revealedSerials[label] == serial;
    return ListTile(
      title: Text(label),
      subtitle: Text(
        serial == null
            ? 'Unavailable'
            : revealed
            ? serial
            : 'Tap to show',
      ),
      trailing: serial == null || revealed
          ? null
          : const Icon(Icons.visibility_outlined),
      enabled: serial != null,
      onTap: serial == null || revealed
          ? null
          : () => setState(() => _revealedSerials[label] = serial),
    );
  }
}
