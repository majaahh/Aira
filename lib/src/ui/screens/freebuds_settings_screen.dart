import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/controllers/headphone_controller.dart';
import '../../core/services/freebuds_service.dart';
import '../widgets/expressive_popup.dart';
import '../widgets/expressive_list_group.dart';

enum FreeBudsPage {
  gestures('Touch gestures', 'gestures'),
  locator('Find my earbuds', 'locator'),
  preferences('Earbud preferences', 'preferences'),
  information('Earbud information', 'information'),
  supportedFeatures('Supported features', 'supported-features');

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
  final _revealedSerials = <String, String>{};
  bool get _available =>
      widget.controller.isConnected && widget.controller.hasFreeBudsControls;

  @override
  void initState() {
    super.initState();
    _connected = _available;
    widget.controller.addListener(_onConnectionChanged);
    if (_connected) _load(refresh: widget.page == FreeBudsPage.locator);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    if (_available == _connected) return;
    setState(() {
      _connected = _available;
      _connectionVersion++;
      _data = {};
      _revealedSerials.clear();
      _error = null;
      _fitResult = null;
      _loading = _connected;
      _busy = false;
    });
    if (_connected) _load(refresh: widget.page == FreeBudsPage.locator);
  }

  Map<String, dynamic> _cachedPage() {
    final controller = widget.controller;
    if (widget.page == FreeBudsPage.supportedFeatures) {
      return {
        ...?controller.cachedFreeBudsPage('information'),
        ...?controller.cachedFreeBudsPage('preferences'),
        ...?controller.cachedFreeBudsPage('gestures'),
      };
    }
    return {...?controller.cachedFreeBudsPage(widget.page.section)};
  }

  Future<void> _load({bool refresh = false}) async {
    if (!_connected) return;
    final version = _connectionVersion;
    setState(() {
      _data = _cachedPage();
      _loading = _data.isEmpty || refresh;
      _error = null;
    });
    try {
      final controller = widget.controller;
      final result = widget.page == FreeBudsPage.supportedFeatures
          ? {
              ...await controller.readFreeBudsPage(
                'information',
                refresh: refresh,
              ),
              ...await controller.readFreeBudsPage(
                'preferences',
                refresh: refresh,
              ),
              ...await controller.readFreeBudsPage(
                'gestures',
                refresh: refresh,
              ),
            }
          : await controller.readFreeBudsPage(
              widget.page.section,
              refresh: refresh,
            );
      if (!mounted || version != _connectionVersion) return;
      setState(() => _data = Map.of(result));
    } catch (error) {
      if (!mounted || version != _connectionVersion) return;
      setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted && version == _connectionVersion) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _change(
    FreeBudsCommand command,
    Map<String, Object> args,
    void Function(Map<String, dynamic>) apply,
  ) async {
    if (!_connected || _busy || _loading) return;
    final version = _connectionVersion;
    setState(() => _busy = true);
    try {
      final result = await widget.controller.runFreeBudsCommand(command, args);
      if (!mounted || version != _connectionVersion) return;
      setState(() => apply(result));
      widget.controller.rememberFreeBudsPage(widget.page.section, _data);
    } catch (error) {
      if (!mounted || version != _connectionVersion) return;
      if (widget.page == FreeBudsPage.locator) {
        _showLocatorError(_errorMessage(error));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_errorMessage(error))));
      }
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
              style: IconButton.styleFrom(
                backgroundColor: theme.colorScheme.surfaceContainerHigh,
                foregroundColor: theme.colorScheme.onSurfaceVariant,
              ),
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
              color: theme.scaffoldBackgroundColor.withValues(alpha: 0.88),
              child: const SizedBox.expand(),
            ),
          ),
        ),
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
    if (_loading &&
        _data.isEmpty &&
        widget.page != FreeBudsPage.supportedFeatures) {
      return const Center(child: CircularProgressIndicator());
    }
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
    if (widget.page == FreeBudsPage.gestures) {
      final pages = _gesturePages();
      if (pages.isNotEmpty) {
        return Padding(
          padding: EdgeInsets.only(top: topInset + 8),
          child: _GesturePager(
            key: ValueKey(pages.keys.join(',')),
            labels: pages.values.toList(),
            pages: [for (final gesture in pages.keys) _gesturePage(gesture)],
            enabled: !_busy && !_loading,
          ),
        );
      }
    }

    final children = switch (widget.page) {
      FreeBudsPage.gestures => <Widget>[],
      FreeBudsPage.locator => _locatorCards(),
      FreeBudsPage.preferences => _preferenceCards(),
      FreeBudsPage.information => _informationCards(),
      FreeBudsPage.supportedFeatures => _supportedFeaturesCards(),
    };
    return ListView(
      padding: EdgeInsets.fromLTRB(16, topInset + 8, 16, 24),
      children: [
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
      ExpressiveListGroup(children: children),
    ],
  );

  Widget _option<T extends Object>(
    String title,
    T? current,
    Map<T, String> options,
    ValueChanged<T> change, {
    String? valueLabel,
  }) {
    final version = _connectionVersion;
    return ExpressiveOptionPicker<T>(
      label: title,
      value: current,
      valueLabel: valueLabel,
      actions: options,
      onSelected: _busy
          ? null
          : (value) {
              if (version == _connectionVersion) change(value);
            },
    );
  }

  Map<String, String> _gesturePages() {
    final gestures = _map(_data['gestures']);
    final cycle = _map(_data['cycle']);
    return {
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
  }

  Widget _gesturePage(String gesture) {
    if (gesture != 'noise_cycle') {
      return _gestureCard(gesture, _map(_map(_data['gestures'])[gesture]));
    }
    final cycle = _map(_data['cycle']);
    final cycleOptions = {
      for (final number in _list<int>(cycle['supported']))
        if (_cycles.containsKey(number)) number: _cycles[number]!,
    };
    return _card(null, [
      for (final ear in _earNames.entries)
        if (cycle[ear.key] case final int current)
          _option('${ear.value} earbud', current, cycleOptions, (value) {
            _change(FreeBudsCommand.noiseCycle, {
              'side': ear.key,
              'cycle': value,
            }, (result) => _data['cycle'] = result);
          }),
    ]);
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
    return _card(null, [
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
    ]);
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
        for (final entry in ears.entries)
          ListTile(
            title: Text('${_earNames[entry.key]} earbud'),
            trailing: FilledButton.tonal(
              onPressed: _busy || _loading
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
        .where((code) => code.trim().isNotEmpty);
    final currentCode = (language['current'] as String?)?.trim();
    String normalize(String code) =>
        code.trim().replaceAll('_', '-').toLowerCase();
    String label(String code) => switch (normalize(code)) {
      'en-gb' => 'English (UK)',
      'en-us' => 'English (US)',
      'en' => 'English',
      'zh-cn' || 'zh-hans' => 'Chinese (Simplified)',
      'zh' => 'Chinese',
      _ => code,
    };
    final current = currentCode == null || currentCode.isEmpty
        ? null
        : codes
                  .where((code) => normalize(code) == normalize(currentCode))
                  .firstOrNull ??
              currentCode;
    final lastKnown = language['lastKnown'] as String?;
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
      if (codes.isNotEmpty || current != null)
        _option(
          'Voice prompt language',
          current,
          {for (final code in codes) code: label(code)},
          (code) {
            _change(FreeBudsCommand.language, {
              'code': code,
            }, (result) => _data['language'] = result);
          },
          valueLabel: current != null
              ? label(current)
              : lastKnown != null
              ? 'Last known: ${label(lastKnown)}'
              : '',
        ),
    ];
    return [
      if (preferences.isNotEmpty) _card(null, preferences),
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux)
        _card('Ear tip fit', [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (_fitResult case final result?)
                  Text(result, style: Theme.of(context).textTheme.bodyLarge),
                FilledButton.tonal(
                  onPressed: _busy || _loading ? null : _confirmFitTest,
                  child: const Text('Run fit test'),
                ),
              ],
            ),
          ),
        ]),
    ];
  }

  Future<void> _confirmFitTest() async {
    final version = _connectionVersion;
    final confirmed = await showExpressiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ear tip fit'),
        content: const Text('Wear both earbuds and stay in a quiet room.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start test'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || version != _connectionVersion) return;
    setState(() => _fitResult = null);
    await _change(FreeBudsCommand.fit, {}, (result) {
      _fitResult = _earNames.entries
          .map((ear) {
            final fit = result[ear.key] == 'good' ? 'Good fit' : 'Adjust fit';
            return '${ear.value}: $fit';
          })
          .join('\n');
    });
  }

  List<Widget> _informationCards() {
    final version = _map(_data['version']);
    final info = <String, Object?>{
      'Model': version['model'],
      'Firmware': version['firmware'],
      'Firmware package': version['ota_package'],
      'Bluetooth version': version['bluetooth_version'],
    };
    final rows = [
      for (final entry in info.entries)
        if (entry.value case final value?)
          _feedbackRow(
            ListTile(title: Text(entry.key), subtitle: Text(value.toString())),
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
      _card(null, [
        ListTile(
          title: Text(FreeBudsPage.supportedFeatures.title),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => FreeBudsSettingsScreen(
                controller: widget.controller,
                page: FreeBudsPage.supportedFeatures,
              ),
            ),
          ),
        ),
      ]),
    ];
  }

  List<Widget> _supportedFeaturesCards() {
    final controller = widget.controller;
    final status = controller.status;
    final gestures = _map(_data['gestures']);
    final language = _map(_data['language']);
    final preferences = _map(_data['features']);
    final modes = status.modelInfo?['eq_modes'];
    final capabilities = <String>[
      'Battery levels',
      'Rename earbuds',
      if (status.hasAnc) 'Noise control',
      if (status.hasAncLevels) 'Noise cancellation levels',
      if (_data['dynamic'] == true) 'Dynamic noise cancellation',
      if (status.gameMode != null) 'Game mode',
      if (status.windNoise != null) 'Wind noise reduction',
      if (status.multipoint != null) 'Multipoint connection',
      if (status.hasLdac) 'LDAC audio',
      if (status.hasWearDetection && status.wearDetection != null)
        'Smart wear detection',
      if (status.hasAntiLeak) 'Anti-sound leak',
      if (status.hasSpatialAudio) 'Spatial audio',
      if (modes is! List || modes.isNotEmpty) 'Sound presets',
      if (status.hasAutoShutdown) 'Hardware auto shutdown',
      if (controller.usesSoftwareShutdown) 'Software disconnect timer',
      for (final entry in _gestureNames.entries)
        if (gestures.containsKey(entry.key)) entry.value,
      if (gestures.values.any((value) => _map(value)['call_supported'] != null))
        'Call gestures',
      if (_map(_data['cycle']).isNotEmpty) 'Noise control cycle',
      'Find my earbuds',
      'Manage paired devices',
      'Set a primary device',
      'Forget paired devices',
      'Automatic reconnect',
      'Automatic audio switching',
      if (language.isNotEmpty) 'Voice prompt language',
      for (final entry in _features.entries)
        if (preferences.containsKey(entry.key)) entry.value,
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.linux)
        'Ear tip fit test',
    ];
    return [
      _card(null, [
        for (final feature in capabilities)
          _feedbackRow(ListTile(title: Text(feature))),
      ]),
    ];
  }

  Widget _feedbackRow(ListTile row) => InkWell(
    onTap: () {},
    canRequestFocus: false,
    excludeFromSemantics: true,
    enableFeedback: false,
    child: row,
  );

  Future<void> _showLocatorError(String message) =>
      showEarbudLocatorNotice(context, message);

  Widget _serialTile(String label, Object? value) {
    final serial = value is String && value.trim().isNotEmpty ? value : null;
    final revealed = serial != null && _revealedSerials[label] == serial;
    final tile = ListTile(
      title: Text(label),
      subtitle: Text(
        serial == null
            ? 'Unavailable'
            : revealed
            ? serial
            : 'Tap to show',
      ),
      enabled: serial != null,
      onTap: serial == null || revealed
          ? null
          : () => setState(() => _revealedSerials[label] = serial),
    );
    return revealed ? _feedbackRow(tile) : tile;
  }
}

class _GesturePager extends StatefulWidget {
  const _GesturePager({
    super.key,
    required this.labels,
    required this.pages,
    required this.enabled,
  });

  final List<String> labels;
  final List<Widget> pages;
  final bool enabled;

  @override
  State<_GesturePager> createState() => _GesturePagerState();
}

class _GesturePagerState extends State<_GesturePager> {
  final _pages = PageController(keepPage: false);
  final _selectedLabel = GlobalKey();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _pages.jumpToPage(index);
    } else {
      _pages.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _pageChanged(int index) {
    setState(() => _index = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final label = _selectedLabel.currentContext;
      if (label == null || !mounted) return;
      Scrollable.ensureVisible(
        label,
        alignment: 0.5,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.pages.length > 1)
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              style: ButtonStyle(
                shape: const WidgetStatePropertyAll(StadiumBorder()),
                visualDensity: VisualDensity.compact,
                animationDuration: Duration.zero,
                splashFactory: NoSplash.splashFactory,
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.pressed)) {
                    return Colors.transparent;
                  }
                  return states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.focused)
                      ? colors.onSurface.withValues(alpha: 0.08)
                      : null;
                }),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
              segments: [
                for (final (index, label) in widget.labels.indexed)
                  ButtonSegment(
                    value: index,
                    label: Text(
                      label,
                      key: index == _index ? _selectedLabel : null,
                    ),
                  ),
              ],
              selected: {_index},
              onSelectionChanged: widget.enabled
                  ? (selection) => _select(selection.first)
                  : null,
            ),
          ),
        Expanded(
          child: PageView.builder(
            controller: _pages,
            onPageChanged: _pageChanged,
            physics: widget.enabled
                ? null
                : const NeverScrollableScrollPhysics(),
            itemCount: widget.pages.length,
            itemBuilder: (context, index) => ListView(
              key: PageStorageKey(index),
              padding: EdgeInsets.fromLTRB(
                16,
                widget.pages.length > 1 ? 12 : 0,
                16,
                24,
              ),
              children: [widget.pages[index]],
            ),
          ),
        ),
      ],
    );
  }
}
