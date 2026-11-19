import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/controllers/headphone_controller.dart';
import '../../core/services/freebuds_service.dart';
import 'expressive_popup.dart';
import 'expressive_list_group.dart';

typedef _PairedDevice = ({
  String address,
  String name,
  int? type,
  bool? connected,
  bool? primary,
  bool? reconnect,
  bool? audioSwitch,
});

class PairedDevicesSection extends StatefulWidget {
  const PairedDevicesSection({
    super.key,
    required this.controller,
    required this.enabled,
  });

  final HeadphoneController controller;
  final bool enabled;

  @override
  State<PairedDevicesSection> createState() => _PairedDevicesSectionState();
}

class _PairedDevicesSectionState extends State<PairedDevicesSection> {
  List<_PairedDevice> _devices = [];
  int _connectionVersion = 0;
  bool _loading = false;
  String? _pendingAddress;
  String? _loadError;

  bool get _canInteract =>
      widget.enabled && !_loading && _pendingAddress == null;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _loadCachedDevices();
  }

  @override
  void didUpdateWidget(covariant PairedDevicesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled == widget.enabled &&
        identical(oldWidget.controller, widget.controller)) {
      return;
    }
    _connectionVersion++;
    _loading = false;
    _pendingAddress = null;
    _loadError = null;
    _devices = [];
    if (widget.enabled) _loadCachedDevices();
  }

  bool _isCurrent(int version) =>
      mounted && widget.enabled && version == _connectionVersion;

  List<_PairedDevice> _readDevices(Map<String, dynamic> result) {
    final entries = result['devices'];
    if (entries is! List) return [];
    final devices = <_PairedDevice>[
      for (final entry in entries.whereType<Map>())
        if (entry['addr'] case final String address when address.isNotEmpty)
          (
            address: address,
            name: switch (entry['name']) {
              final String name when name.trim().isNotEmpty => name.trim(),
              _ => address,
            },
            type: entry['type'] as int?,
            connected: switch (entry['conn_state']) {
              1 => true,
              0 => false,
              _ => null,
            },
            primary: switch (entry['primary']) {
              1 => true,
              0 => false,
              _ => null,
            },
            reconnect: switch (entry['back_conn_permit']) {
              1 => true,
              0 => false,
              _ => null,
            },
            audioSwitch: entry['allow_audio_auto_switch'] as bool?,
          ),
    ];
    return [
      ...devices.where((device) => device.connected == true),
      ...devices.where((device) => device.connected != true),
    ];
  }

  void _loadCachedDevices() {
    final result = widget.controller.cachedFreeBudsPage('devices');
    if (result == null) {
      _refresh(useCache: true);
    } else {
      _devices = _readDevices(result);
    }
  }

  Future<void> _refresh({bool useCache = false}) async {
    if (!_canInteract) return;
    final version = _connectionVersion;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.controller.readFreeBudsPage(
        'devices',
        refresh: !useCache,
      );
      if (_isCurrent(version)) setState(() => _devices = _readDevices(result));
    } catch (error) {
      if (_isCurrent(version)) setState(() => _loadError = _message(error));
    } finally {
      if (_isCurrent(version)) setState(() => _loading = false);
    }
  }

  Future<void> _showDeviceOptions(_PairedDevice device) async {
    if (!_canInteract) return;
    final version = _connectionVersion;
    var applyingSetting = false;
    final action = await showExpressiveDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final theme = Theme.of(context);
          final current =
              _devices
                  .where((entry) => entry.address == device.address)
                  .firstOrNull ??
              device;
          final enabled = !applyingSetting && _isCurrent(version);

          Future<void> applySetting(String action, {bool? value}) async {
            setDialogState(() => applyingSetting = true);
            await _runDeviceAction(current, action, enabled: value);
            if (context.mounted) setDialogState(() => applyingSetting = false);
          }

          return AlertDialog(
            scrollable: true,
            title: Text(current.name),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            content: SizedBox(
              width: 380,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTileTheme(
                    data: ListTileTheme.of(context)
                        .copyWith(minLeadingWidth: 24, horizontalTitleGap: 8),
                    child: ExpressiveListGroup(
                      children: [
                        ListTile(
                          leading: Icon(
                            current.primary == true
                                ? Icons.star_rounded
                                : Icons.star_outline_rounded,
                          ),
                          title: const Text('Primary device'),
                          subtitle: Text(
                            current.primary == true
                                ? 'Preferred connection'
                                : 'Set as the preferred connection',
                          ),
                          trailing: current.primary == true
                              ? const Icon(Icons.check_rounded)
                              : const Icon(Icons.add_circle_outline_rounded),
                          onTap: enabled && current.primary != true
                              ? () => applySetting('primary')
                              : null,
                        ),
                        if (current.reconnect case final reconnect?)
                          SwitchListTile(
                            secondary: const Icon(Icons.link_rounded),
                            title:
                                MediaQuery.textScalerOf(context).scale(16) > 20
                                ? const Text('Automatic reconnect')
                                : const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: AlignmentDirectional.centerStart,
                                    child: Text('Automatic reconnect'),
                                  ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            value: reconnect,
                            onChanged: enabled
                                ? (value) =>
                                      applySetting('reconnect', value: value)
                                : null,
                          ),
                        if (current.audioSwitch case final audioSwitch?)
                          SwitchListTile(
                            secondary: const Icon(Icons.swap_horiz_rounded),
                            title: const Text('Automatic audio switching'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                            ),
                            value: audioSwitch,
                            onChanged: enabled
                                ? (value) =>
                                      applySetting('audio-switch', value: value)
                                : null,
                          ),
                      ],
                    ),
                  ),
                  if (applyingSetting)
                    const Padding(
                      padding: EdgeInsets.only(top: 12, bottom: 2),
                      child: LinearProgressIndicator(
                        borderRadius: BorderRadius.zero,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: enabled
                    ? () => Navigator.pop(dialogContext, 'unpair')
                    : null,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                child: const Text('Forget device'),
              ),
              FilledButton.tonal(
                onPressed: enabled
                    ? () => Navigator.pop(dialogContext, 'toggle')
                    : null,
                child: Text(
                  current.connected == true ? 'Disconnect' : 'Connect',
                ),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || action == null || !_isCurrent(version) || !_canInteract) {
      return;
    }
    if (action == 'toggle') {
      await _toggle(device);
      return;
    }
    if (action == 'unpair') {
      final confirmed = await showExpressiveDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Forget ${device.name}?'),
          content: const Text(
            'You’ll need to pair this device with the earbuds again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Forget'),
            ),
          ],
        ),
      );
      if (confirmed != true || !_isCurrent(version) || !_canInteract) return;
    }
    await _runDeviceAction(device, action);
  }

  Future<void> _toggle(_PairedDevice device) async {
    if (!_canInteract) return;
    final version = _connectionVersion;
    final connect = device.connected != true;
    if (!connect) {
      final confirmed = await showExpressiveDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Disconnect ${device.name}?'),
          content: const Text('The earbuds will disconnect from this device.'),
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
      if (confirmed != true || !_isCurrent(version) || !_canInteract) return;
    }

    await _runDeviceAction(
      device,
      connect ? 'connect' : 'disconnect',
      expectedConnection: connect,
    );
  }

  Future<void> _runDeviceAction(
    _PairedDevice device,
    String action, {
    bool? enabled,
    bool? expectedConnection,
  }) async {
    if (!_canInteract) return;
    final version = _connectionVersion;
    setState(() => _pendingAddress = device.address);
    try {
      final controller = widget.controller;
      final result = await controller.runFreeBudsCommand(
        FreeBudsCommand.device,
        {'mac': device.address, 'action': action, 'enabled': ?enabled},
      );
      if (!_isCurrent(version)) return;
      controller.rememberFreeBudsPage('devices', result);
      var updated = _readDevices(result);
      bool confirmed() =>
          expectedConnection == null ||
          updated
                  .where((entry) => entry.address == device.address)
                  .firstOrNull
                  ?.connected ==
              expectedConnection;
      if (!confirmed()) {
        setState(() => _devices = updated);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!_isCurrent(version)) return;
        updated = _readDevices(
          await controller.readFreeBudsPage('devices', refresh: true),
        );
        if (!_isCurrent(version)) return;
      }
      setState(() => _devices = updated);
      if (!confirmed()) {
        _showError(
          expectedConnection == true
              ? 'The earbuds haven’t confirmed the connection.'
              : 'The earbuds haven’t confirmed the disconnection.',
        );
      }
    } catch (error) {
      if (_isCurrent(version)) _showError(_message(error));
    } finally {
      if (_isCurrent(version)) setState(() => _pendingAddress = null);
    }
  }

  String _message(Object error) => switch (error) {
    StateError(:final message) => message,
    PlatformException(:final message) =>
      message ?? 'The earbuds did not respond.',
    _ => 'The earbuds did not respond.',
  };

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Paired devices', style: theme.textTheme.titleSmall),
            ),
            if (widget.enabled)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Refresh paired devices',
                onPressed: _canInteract ? _refresh : null,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
          ],
        ),
        SizedBox(height: widget.enabled ? 4 : 12),
        ExpressiveListGroup(
          color: theme.colorScheme.surfaceContainerLow,
          children: [
            for (final device in _devices) _buildDeviceRow(device),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              )
            else if (_loadError case final error?)
              ListTile(
                title: Text(error),
                trailing: TextButton(
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              )
            else if (_devices.isEmpty)
              ListTile(
                title: Text(
                  widget.enabled
                      ? 'No paired devices'
                      : widget.controller.isConnected
                      ? 'Reading device information…'
                      : 'Connect your earbuds to see paired devices.',
                ),
              ),
          ],
        ),
      ],
    );
  }

  static final _tablet = RegExp(
    r'ipad|tablet|galaxy tab',
    caseSensitive: false,
  );
  static final _phone = RegExp(
    r'iphone|pixel|galaxy [aszmfu]\d|phone|oneplus|redmi|poco',
    caseSensitive: false,
  );
  static final _computer = RegExp(
    r'bluez|macbook|imac|laptop|desktop|windows|linux|thinkpad',
    caseSensitive: false,
  );

  IconData _deviceIcon(_PairedDevice device) {
    // Huawei's paired-device types, as used by AI Life's DeviceResourceUtils.
    return switch (device.type) {
      1 => Icons.smartphone_rounded,
      2 => Icons.watch_rounded,
      3 => Icons.tablet_android_rounded,
      4 => Icons.computer_rounded,
      5 => Icons.tv_rounded,
      _ when _tablet.hasMatch(device.name) => Icons.tablet_android_rounded,
      _ when _phone.hasMatch(device.name) => Icons.smartphone_rounded,
      _ when _computer.hasMatch(device.name) => Icons.computer_rounded,
      _ => Icons.devices_other_rounded,
    };
  }

  Widget _buildDeviceRow(_PairedDevice device) {
    final colors = Theme.of(context).colorScheme;
    final connected = device.connected == true;
    final pending = _pendingAddress == device.address;
    return ListTile(
      key: ValueKey(device.address),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: connected
            ? colors.secondaryContainer
            : colors.surfaceContainerHighest,
        foregroundColor: connected
            ? colors.onSecondaryContainer
            : colors.onSurfaceVariant,
        child: Icon(
          connected ? Icons.bluetooth_connected : _deviceIcon(device),
          size: 19,
        ),
      ),
      title: Text(device.name),
      subtitle: Text(
        pending
            ? 'Updating…'
            : switch (device.connected) {
                true => 'Connected',
                false => 'Disconnected',
                null => 'Connection unavailable',
              },
      ),
      trailing: pending
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.chevron_right_rounded),
      onTap: _canInteract ? () => _showDeviceOptions(device) : null,
    );
  }
}
