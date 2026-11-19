import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../ui/theme/theme_controller.dart';
import '../models/bluetooth_device.dart';
import '../models/headphone_status.dart';
import '../services/headphone_service.dart';
import '../services/android_service.dart';
import '../services/desktop_service.dart';
import '../services/freebuds_service.dart';
import '../services/simulation_service.dart';

class HeadphoneController extends ChangeNotifier {
  HeadphoneController(this.themeController, {bool connectOnStartup = true}) {
    _initService();
    themeController.addListener(_onThemeSettingsChanged);
    if (connectOnStartup) startAutoConnect();
  }

  final ThemeController themeController;
  late HeadphoneService _service;
  StreamSubscription<HeadphoneStatus>? _statusSub;
  StreamSubscription<void>? _bluetoothSub;
  HeadphoneStatus _status = HeadphoneStatus.disconnected();
  Timer? _autoConnectTimer;
  bool _checkingBluetooth = false;
  bool _requestingAudio = false;
  bool _requestedBluetoothPermission = false;
  bool _disconnecting = false;
  int _connectionRequest = 0;
  String? _activeMac;
  String? _connectingMac;
  String? _pendingAudioAddress;
  final _pageData = <String, Map<String, dynamic>>{};
  final _pageReads = <String, Future<Map<String, dynamic>>>{};
  int _pageSession = 0;
  bool _canReadPages = false;
  final _manuallyDisconnected = <String, bool>{};
  final _lastAutoAttempt = <String, DateTime>{};
  final _lastAudioAttempt = <String, DateTime>{};
  static final _freeBudsName = RegExp(
    r'free[\s-]?buds?|fly[\s-]?pods',
    caseSensitive: false,
  );

  HeadphoneStatus get status => _status;
  bool get isConnected => _status.isConnected;
  bool get isConnecting => _status.isConnecting;
  String get deviceName => _status.deviceName;
  int get batteryPercent => _status.batteryPercent;

  bool get hasFreeBudsControls =>
      _service is FreeBudsService && _status.modelInfo?['key'] == 'FREEBUDS_5I';

  Future<Map<String, dynamic>> runFreeBudsCommand(
    FreeBudsCommand command, [
    Map<String, Object> arguments = const {},
  ]) async {
    final service = _service;
    if (!isConnected || !hasFreeBudsControls || service is! FreeBudsService) {
      throw StateError('FreeBuds controls are unavailable');
    }
    final address = _activeMac?.toUpperCase();
    final result = await (service as FreeBudsService).runFreeBudsCommand(command, arguments);
    if (address == null) return result;
    final preferences = command == FreeBudsCommand.controls && arguments['section'] == 'preferences';
    final language = preferences ? result['language'] : result;
    if ((preferences || command == FreeBudsCommand.language) && language is Map) {
      final key = 'prompt_language_$address';
      final current = language['current'];
      try {
        final prefs = await SharedPreferences.getInstance();
        if (current is String && current.isNotEmpty) {
          await prefs.setString(key, current);
        } else if (preferences) {
          final last = prefs.getString(key);
          if (last != null && (language['supported'] as List?)?.contains(last) == true) {
            return {...result, 'language': {...language, 'lastKnown': last}};
          }
        }
      } on Exception {
        // The device reply is still usable if local storage is unavailable.
      }
    }
    return result;
  }

  Map<String, dynamic>? cachedFreeBudsPage(String section) =>
      _pageData[section];

  void rememberFreeBudsPage(String section, Map<String, dynamic> data) {
    if (isConnected && hasFreeBudsControls) _pageData[section] = Map.of(data);
  }

  Future<Map<String, dynamic>> readFreeBudsPage(
    String section, {
    bool refresh = false,
  }) {
    if (!refresh && _pageData[section] != null) {
      return Future.value(_pageData[section]!);
    }
    final session = _pageSession;
    return _pageReads.putIfAbsent(
      section,
      () => Future.microtask(() async {
        try {
          if (session != _pageSession) {
            throw StateError('FreeBuds disconnected');
          }
          final data = section == 'information'
              ? await runFreeBudsCommand(FreeBudsCommand.information)
              : section == 'devices'
              ? await runFreeBudsCommand(FreeBudsCommand.devices)
              : await runFreeBudsCommand(FreeBudsCommand.controls, {
                  'section': section,
                });
          if (session != _pageSession) {
            throw StateError('FreeBuds disconnected');
          }
          rememberFreeBudsPage(section, data);
          return data;
        } finally {
          if (session == _pageSession) _pageReads.remove(section);
        }
      }),
    );
  }

  void _resetPageData() {
    _canReadPages = false;
    _pageSession++;
    _pageData.clear();
    _pageReads.clear();
  }

  Future<void> _preloadPages(int session) async {
    for (final section in [
      'devices',
      'gestures',
      'information',
      'preferences',
      'locator',
    ]) {
      if (session != _pageSession) return;
      try {
        await readFreeBudsPage(section);
      } catch (_) {
        // A failed background request can be retried when the page opens.
      }
    }
  }

  void _initService() {
    _resetPageData();
    _statusSub?.cancel();
    _bluetoothSub?.cancel();

    if (themeController.isMockConnected) {
      _service = SimulationHeadphoneService(themeController);
    } else {
      if (defaultTargetPlatform == TargetPlatform.android) {
        _service = AndroidHeadphoneService();
      } else {
        _service = DesktopHeadphoneService();
      }
    }

    final service = _service;
    if (service is AndroidHeadphoneService) {
      _bluetoothSub = service.bluetoothChanges.listen(
        (_) => checkForConnectedDevices(),
      );
    }

    final initialName = themeController.lastConnectedName;
    _status = _service.currentStatus;
    if (!_status.isConnected && initialName.isNotEmpty && _status.deviceName == 'Disconnected') {
      _status = _status.copyWith(deviceName: initialName);
    }

    _statusSub = _service.statusStream.listen((newStatus) {
      if (!newStatus.isConnected && initialName.isNotEmpty && newStatus.deviceName == 'Disconnected') {
        _status = newStatus.copyWith(deviceName: initialName);
      } else {
        _status = newStatus;
      }

      if (newStatus.isConnected) {
        final currentMac = themeController.lastConnectedMac;
        final targetMac = _connectingMac ?? currentMac;

        if (_connectingMac != null) {
          _activeMac = _connectingMac;
          themeController.setLastConnectedMac(_connectingMac!);
          _connectingMac = null;
        }

        if (newStatus.deviceName.isNotEmpty && newStatus.deviceName.toLowerCase() != 'disconnected') {
          themeController.setLastConnectedName(newStatus.deviceName);
          if (targetMac.isNotEmpty) {
            themeController.saveDeviceName(targetMac, newStatus.deviceName);
          }
        }
      } else if (!newStatus.isConnecting &&
          !service.currentStatus.isConnected &&
          !service.currentStatus.isConnecting) {
        _activeMac = null;
        _connectingMac = null;
      }
      if (isConnected && hasFreeBudsControls) {
        if (!_canReadPages) {
          _canReadPages = true;
          unawaited(_preloadPages(_pageSession));
        }
      } else if (_canReadPages) {
        _resetPageData();
      }
      notifyListeners();
    });
  }

  void startAutoConnect() {
    if (_autoConnectTimer != null) return;
    final interval = _service is AndroidHeadphoneService
        ? const Duration(seconds: 12)
        : const Duration(seconds: 5);
    _autoConnectTimer = Timer.periodic(
      interval,
      (_) => checkForConnectedDevices(),
    );
    checkForConnectedDevices();
  }

  void checkForConnectedDevices() => unawaited(_checkForConnectedDevices());

  bool get _canAutoConnect =>
      _autoConnectTimer != null &&
      !_disconnecting &&
      !_requestingAudio &&
      !_service.currentStatus.isConnected &&
      !_service.currentStatus.isConnecting;

  Future<void> _checkForConnectedDevices() async {
    final service = _service;
    if (!_canAutoConnect ||
        _checkingBluetooth ||
        service is SimulationHeadphoneService) {
      return;
    }

    _checkingBluetooth = true;
    final request = _connectionRequest;
    try {
      final requestPermission =
          service is AndroidHeadphoneService && !_requestedBluetoothPermission;
      if (requestPermission) _requestedBluetoothPermission = true;
      final connected = await service.getConnectedDevices(
        requestPermission: requestPermission,
      );
      if (connected == null ||
          request != _connectionRequest ||
          !_canAutoConnect) {
        return;
      }
      final activeAddresses = connected
          .map((device) => device.macAddress.toUpperCase())
          .toSet();
      // A fresh system audio connection supersedes an earlier Aira disconnect.
      _manuallyDisconnected.removeWhere(
        (address, audioWentAway) =>
            audioWentAway && activeAddresses.contains(address),
      );
      _manuallyDisconnected.updateAll(
        (address, audioWentAway) =>
            audioWentAway || !activeAddresses.contains(address),
      );
      final last = themeController.lastConnectedMac.toUpperCase();
      final now = DateTime.now();
      BluetoothDevice? target;
      for (final device in connected) {
        final address = device.macAddress.toUpperCase();
        final previousAttempt = _lastAutoAttempt[address];
        if (address.isEmpty ||
            _manuallyDisconnected.containsKey(address) ||
            (previousAttempt != null &&
                now.difference(previousAttempt) < const Duration(seconds: 20)) ||
            (service is AndroidHeadphoneService &&
                service.wasDisconnectedByTimer(address))) {
          continue;
        }
        if (address == (_pendingAudioAddress ?? last)) {
          target = device;
          break;
        }
        if (_freeBudsName.hasMatch(device.name)) target ??= device;
      }
      if (target != null) {
        final address = target.macAddress.toUpperCase();
        _lastAutoAttempt[address] = now;
        await connect(address, target.name);
      } else if (service is AndroidHeadphoneService) {
        var address = last;
        String? name;
        if (address.isEmpty) {
          final earbuds = (await service.getPairedDevices(
            requestPermission: false,
          )).where((device) => _freeBudsName.hasMatch(device.name)).toList();
          if (earbuds.length == 1) {
            address = earbuds.single.macAddress.toUpperCase();
            name = earbuds.single.name;
          }
        }
        final attempted = _lastAudioAttempt[address];
        if (address.isEmpty ||
            request != _connectionRequest ||
            !_canAutoConnect ||
            _manuallyDisconnected.containsKey(address) ||
            service.wasDisconnectedByTimer(address) ||
            (attempted != null &&
                now.difference(attempted) < const Duration(seconds: 20))) {
          return;
        }
        _lastAudioAttempt[address] = now;
        final ready = await service.connectBluetoothAudio(
          address,
          interactive: false,
        );
        if (ready && request == _connectionRequest && _canAutoConnect) {
          await connect(address, name);
        }
      }
    } finally {
      _checkingBluetooth = false;
    }
  }

  void _onThemeSettingsChanged() {
    final shouldBeMock = themeController.isMockConnected;
    final isCurrentlyMock = _service is SimulationHeadphoneService;

    if (shouldBeMock != isCurrentlyMock) {
      _connectionRequest++;
      _activeMac = null;
      _connectingMac = null;
      _statusSub?.cancel();
      _service.dispose();

      _initService();
      checkForConnectedDevices();
      notifyListeners();
    }
  }

  Future<bool> connectFromPicker(String mac, String name) async {
    final service = _service;
    if (service is! AndroidHeadphoneService) {
      await connect(mac, name);
      return true;
    }
    if (_requestingAudio ||
        _disconnecting ||
        service.currentStatus.isConnecting) {
      return false;
    }
    _requestingAudio = true;
    final request = ++_connectionRequest;
    try {
      final ready = await service.connectBluetoothAudio(mac, interactive: true);
      if (request != _connectionRequest || !identical(service, _service)) {
        return false;
      }
      if (!ready) {
        _pendingAudioAddress = mac.toUpperCase();
        _manuallyDisconnected.remove(_pendingAudioAddress);
        _lastAutoAttempt.remove(_pendingAudioAddress);
        return false;
      }
      await connect(mac, name);
      return true;
    } finally {
      _requestingAudio = false;
    }
  }

  Future<void> connect(String macAddress, [String? deviceName]) async {
    if (_disconnecting || _service.currentStatus.isConnecting) return;
    _connectionRequest++;
    _pendingAudioAddress = null;
    _manuallyDisconnected.remove(macAddress.toUpperCase());
    _connectingMac = macAddress;
    final name = (deviceName != null && deviceName.isNotEmpty)
        ? deviceName
        : themeController.getDeviceName(macAddress, '');
    if (name.isNotEmpty && name.toLowerCase() != 'disconnected') {
      themeController.saveDeviceName(macAddress, name);
      themeController.setLastConnectedName(name);
      _status = _status.copyWith(deviceName: name);
    }
    await _service.connect(macAddress);
  }

  Future<bool> disconnect() async {
    if (_disconnecting) return false;
    _connectionRequest++;
    final address = _activeMac ?? _connectingMac;
    if (address != null) _manuallyDisconnected[address.toUpperCase()] = false;
    _disconnecting = true;
    final service = _service;
    try {
      if (service is AndroidHeadphoneService) {
        return await service.disconnectFromBluetooth();
      }
      await service.disconnect();
      return true;
    } finally {
      _disconnecting = false;
    }
  }

  Future<List<BluetoothDevice>> getConnectedBluetoothDevices() async {
    return await _service.getConnectedDevices(requestPermission: true) ?? [];
  }

  Future<List<BluetoothDevice>> getPairedDevices() async {
    return await _service.getPairedDevices();
  }

  Future<List<BluetoothDevice>> scanDevices() async {
    return await _service.scanDevices();
  }

  Future<void> setAncMode(int mode) async {
    await _service.setAncMode(mode);
  }

  Future<void> setAncLevel(int level) async {
    await _service.setAncLevel(level);
  }

  Future<void> setGameMode(bool enabled) async {
    await _service.setGameMode(enabled);
  }

  Future<void> setWindNoise(bool enabled) async {
    await _service.setWindNoise(enabled);
  }

  Future<void> setMultipoint(bool enabled) async {
    await _service.setMultipoint(enabled);
  }

  Future<void> setLdac(bool enabled) async {
    await _service.setLdac(enabled);
  }

  Future<void> setWearDetection(bool enabled) async {
    await _service.setWearDetection(enabled);
  }

  Future<void> setAntiLeak(bool enabled) async {
    await _service.setAntiLeak(enabled);
  }

  Future<void> setGesture(int gestureType, int leftFunc, int rightFunc) async {
    await _service.setGesture(gestureType, leftFunc, rightFunc);
  }

  Future<void> setAutoShutdown(int choiceIndex) async {
    // Map choiceIndex (0=30m, 1=1h, 2=3h, 3=5h, 4=Never) to Liesheng protocol byte values:
    // 0 -> 1 (30 mins)
    // 1 -> 2 (1 hour)
    // 2 -> 6 (3 hours)
    // 3 -> 10 (5 hours)
    // 4 -> 255 (Never)
    int byteVal;
    switch (choiceIndex) {
      case 0: byteVal = 1; break;
      case 1: byteVal = 2; break;
      case 2: byteVal = 6; break;
      case 3: byteVal = 10; break;
      case 4: byteVal = 255; break;
      default: byteVal = 255;
    }
    await _service.setAutoShutdown(byteVal);
  }

  Future<void> setAutoShutdownSeconds(int seconds) {
    return switch (_service) {
      AndroidHeadphoneService service => service.setAutoShutdownSeconds(seconds),
      SimulationHeadphoneService service => service.setAutoShutdownSeconds(seconds),
      _ => Future.error(UnsupportedError('Custom auto shutdown timer')),
    };
  }

  bool get usesSoftwareShutdown =>
      _service is AndroidHeadphoneService &&
      _status.modelInfo != null &&
      (!_status.hasAutoShutdown || softwareShutdown != null);

  ({int seconds, DateTime deadline, bool bluetooth})? get softwareShutdown =>
      switch (_service) {
        AndroidHeadphoneService service => service.softwareShutdown,
        _ => null,
      };

  bool get softwareBluetoothDisconnectFailed => switch (_service) {
    AndroidHeadphoneService service => service.softwareBluetoothDisconnectFailed,
    _ => false,
  };

  Future<void> setSpatialAudio(String mode) async {
    await _service.setSpatialAudio(mode);
  }

  Future<void> setSpatialScene(int sceneIdx) async {
    await _service.setSpatialScene(sceneIdx);
  }

  Future<void> setEqPreset(int presetIdx) async {
    await _service.setEqPreset(presetIdx);
  }

  Future<void> setCustomEq(List<double> gains) async {
    await _service.setCustomEq(gains);
  }

  Future<void> renameDevice(String newName) async {
    await _service.renameDevice(newName);
  }

  Future<void> findDevice(bool play) async {
    await _service.findDevice(play);
  }

  Future<void> refreshStatus() async {
    await _service.refreshStatus();
  }

  @override
  void dispose() {
    _resetPageData();
    _connectionRequest++;
    _autoConnectTimer?.cancel();
    _autoConnectTimer = null;
    _bluetoothSub?.cancel();
    themeController.removeListener(_onThemeSettingsChanged);
    _statusSub?.cancel();
    _service.dispose();
    super.dispose();
  }
}
