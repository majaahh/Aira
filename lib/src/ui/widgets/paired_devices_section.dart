import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/controllers/headphone_controller.dart';
import '../../core/services/freebuds_service.dart';
import 'expressive_popup.dart';

typedef _PairedDevice = ({
  String address,
  String name,
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
    if (widget.enabled) _refresh();
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
    if (widget.enabled) _refresh();
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

  Future<void> _refresh() async {
    if (!_canInteract) return;
    final version = _connectionVersion;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.controller.runFreeBudsCommand(
        FreeBudsCommand.devices,
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

          return Dialog(
            backgroundColor: theme.colorScheme.surfaceContainer,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            current.name,
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: MaterialLocalizations.of(context)
                              .closeButtonTooltip,
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            title: const Text('Primary device'),
                            subtitle: Text(switch (current.primary) {
                              true => 'Yes',
                              false => 'No',
                              null => 'Unknown',
                            }),
                            trailing: current.primary == true
                                ? const Icon(Icons.check_rounded)
                                : TextButton(
                                    onPressed: enabled
                                        ? () => applySetting('primary')
                                        : null,
                                    child: const Text('Set as primary'),
                                  ),
                          ),
                          if (current.reconnect case final reconnect?)
                            SwitchListTile(
                              title: const Text('Automatic reconnect'),
                              value: reconnect,
                              onChanged: enabled
                                  ? (value) =>
                                        applySetting('reconnect', value: value)
                                  : null,
                            ),
                          if (current.audioSwitch case final audioSwitch?)
                            SwitchListTile(
                              title: const Text('Automatic audio switching'),
                              value: audioSwitch,
                              onChanged: enabled
                                  ? (value) => applySetting(
                                      'audio-switch',
                                      value: value,
                                    )
                                  : null,
                            ),
                        ],
                      ),
                    ),
                    if (applyingSetting) const LinearProgressIndicator(),
                    const SizedBox(height: 4),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 4,
                      children: [
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
                            current.connected == true
                                ? 'Disconnect'
                                : 'Connect',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
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
          await controller.runFreeBudsCommand(FreeBudsCommand.devices),
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
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          color: theme.colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_devices.isNotEmpty) _buildCards(),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: LinearProgressIndicator(),
                  )
                else if (_loadError case final error?)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(error),
                    trailing: TextButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  )
                else if (_devices.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Text(
                      widget.enabled
                          ? 'No paired devices'
                          : 'Connect your earbuds to see paired devices.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCards() {
    final behavior = ScrollConfiguration.of(context);
    final textGrowth = MediaQuery.textScalerOf(context).scale(54) - 54;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth * 0.46).clamp(138.0, 196.0);
        return SizedBox(
          height: 78 + textGrowth.clamp(0.0, double.infinity),
          child: ScrollConfiguration(
            behavior: behavior.copyWith(
              dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _devices.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, index) {
                final device = _devices[index];
                return SizedBox(
                  key: ValueKey(device.address),
                  width: width,
                  child: _buildCard(device),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard(_PairedDevice device) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final connected = device.connected == true;
    final pending = _pendingAddress == device.address;
    final foreground = connected ? colors.onPrimaryContainer : colors.onSurface;
    final status = pending
        ? 'Updating…'
        : switch (device.connected) {
            true => 'Connected',
            false => 'Disconnected',
            null => 'Connection unavailable',
          };
    return Material(
      color: connected
          ? colors.primaryContainer
          : colors.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: connected
              ? colors.primary.withValues(alpha: 0.55)
              : colors.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _canInteract ? () => _toggle(device) : null,
        onLongPress: _canInteract ? () => _showDeviceOptions(device) : null,
        onSecondaryTap: _canInteract ? () => _showDeviceOptions(device) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            spacing: 8,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: connected
                      ? colors.primary
                      : colors.surfaceContainerHigh,
                ),
                child: pending
                    ? const SizedBox.square(
                        dimension: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        connected
                            ? Icons.bluetooth_connected_rounded
                            : Icons.devices_rounded,
                        size: 16,
                        color: connected ? colors.onPrimary : foreground,
                      ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      device.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      status,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: connected ? foreground : colors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
