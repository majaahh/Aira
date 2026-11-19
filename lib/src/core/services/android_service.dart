import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/bluetooth_device.dart';
import '../models/headphone_status.dart';
import 'freebuds_service.dart';
import 'headphone_service.dart';

part 'android_freebuds.dart';

/// Android backend speaking the Huawei FreeBuds RFCOMM protocol.
class AndroidHeadphoneService implements HeadphoneService, FreeBudsService {
  static const MethodChannel _methodChannel = MethodChannel('io.majaahh.aira/bluetooth');
  static const EventChannel _eventChannel = EventChannel('io.majaahh.aira/bluetooth_events');

  static const List<int> _batteryCmd = [0x01, 0x08, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00];
  static const List<int> _versionCmd = [
    0x01, 0x07, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00, 0x05, 0x00,
    0x06, 0x00, 0x07, 0x00, 0x08, 0x00, 0x09, 0x00, 0x0A, 0x00, 0x0B, 0x00,
    0x0C, 0x00, 0x0F, 0x00, 0x18, 0x00, 0x19, 0x00,
  ];
  static const List<int> _ancCmd = [0x2B, 0x05, 0x01, 0x00];
  static const List<int> _eqCmd = [0x2B, 0x4A, 0x02, 0x00];
  static const List<int> _dormantCmd = [0x2B, 0x48, 0x01, 0x00];
  static const _commandSucceeded = 100000;
  static const _commandUnsupported = 100003;

  static const Map<String, List<int>> _featureGets = {
    'glat': [0x2B, 0x6C, 0x02, 0x00],
    'dual': [0x2B, 0x2F, 0x01, 0x00],
    'hd': [0x2B, 0xA3, 0x01, 0x01],
    'wind': [0x2B, 0x95, 0x01, 0x01],
    'wear': [0x2B, 0x11, 0x01, 0x00],
  };
  static const Map<String, int> _featureSetCmds = {
    'glat': 0x6C,
    'dual': 0x2E,
    'hd': 0xA2,
    'wind': 0x94,
    'wear': 0x10,
  };
  static const Map<String, List<int>> _gestureGets = {
    'double_click': [0x01, 0x20, 0x01, 0x00, 0x02, 0x00],
    'triple_click': [0x01, 0x26, 0x01, 0x00, 0x02, 0x00],
    'long_press': [0x2B, 0x17, 0x01, 0x00, 0x02, 0x00],
  };
  static const Map<String, List<int>> _gestureSetHeaders = {
    'double_click': [0x01, 0x1F],
    'triple_click': [0x01, 0x25],
    'long_press': [0x2B, 0x16],
  };

  static const List<int> _crcTable = [
  0, 4129, 8258, 12387, 16516, 20645, 24774, 28903,
  -32504, -28375, -24246, -20117, -15988, -11859, -7730, -3601,
  4657, 528, 12915, 8786, 21173, 17044, 29431, 25302,
  -27847, -31976, -19589, -23718, -11331, -15460, -3073, -7202,
  9314, 13379, 1056, 5121, 25830, 29895, 17572, 21637,
  -23190, -19125, -31448, -27383, -6674, -2609, -14932, -10867,
  13907, 9842, 5649, 1584, 30423, 26358, 22165, 18100,
  -18597, -22662, -26855, -30920, -2081, -6146, -10339, -14404,
  18628, 22757, 26758, 30887, 2112, 6241, 10242, 14371,
  -13876, -9747, -5746, -1617, -30392, -26263, -22262, -18133,
  23285, 19156, 31415, 27286, 6769, 2640, 14899, 10770,
  -9219, -13348, -1089, -5218, -25735, -29864, -17605, -21734,
  27814, 31879, 19684, 23749, 11298, 15363, 3168, 7233,
  -4690, -625, -12820, -8755, -21206, -17141, -29336, -25271,
  32407, 28342, 24277, 20212, 15891, 11826, 7761, 3696,
  -97, -4162, -8227, -12292, -16613, -20678, -24743, -28808,
  -28280, -32343, -20022, -24085, -12020, -16083, -3762, -7825,
  4224, 161, 12482, 8419, 20484, 16421, 28742, 24679,
  -31815, -27752, -23557, -19494, -15555, -11492, -7297, -3234,
  689, 4752, 8947, 13010, 16949, 21012, 25207, 29270,
  -18966, -23093, -27224, -31351, -2706, -6833, -10964, -15091,
  13538, 9411, 5280, 1153, 29798, 25671, 21540, 17413,
  -22565, -18438, -30823, -26696, -6305, -2178, -14563, -10436,
  9939, 14066, 1681, 5808, 26199, 30326, 17941, 22068,
  -9908, -13971, -1778, -5841, -26168, -30231, -18038, -22101,
  22596, 18533, 30726, 26663, 6336, 2273, 14466, 10403,
  -13443, -9380, -5313, -1250, -29703, -25640, -21573, -17510,
  19061, 23124, 27191, 31254, 2801, 6864, 10931, 14994,
  -722, -4849, -8852, -12979, -16982, -21109, -25112, -29239,
  31782, 27655, 23652, 19525, 15522, 11395, 7392, 3265,
  -4321, -194, -12451, -8324, -20581, -16454, -28711, -24584,
  28183, 32310, 20053, 24180, 11923, 16050, 3793, 7920,
  ];

  AndroidHeadphoneService() {
    _status = HeadphoneStatus.disconnected();
    _controller = StreamController<HeadphoneStatus>.broadcast(onListen: () {
      _controller.add(_status);
    });

    _eventSubscription = _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final ev = event['event'] as String?;
        final val = event['value'];
        if (ev == 'status') {
          if (val == 'connecting') {
            _updateStatus(_status.copyWith(isConnecting: true, isConnected: false));
          } else if (val == 'connected') {
            _updateStatus(_status.copyWith(isConnecting: false, isConnected: true));
            _queryStatus();
          } else if (val == 'disconnected' || val == 'failed') {
            _updateStatus(HeadphoneStatus.disconnected());
          }
        } else if (ev == 'data') {
          _handleIncomingBytes(val is Uint8List ? val : (val as List).cast<int>());
        } else if (ev == 'bluetooth_changed') {
          _bluetoothChanges.add(null);
        }
      }
    });
  }

  late HeadphoneStatus _status;
  late final StreamSubscription<dynamic> _eventSubscription;
  String? _connectedMac;
  String? _timedDisconnectMac;
  final _bluetoothChanges = StreamController<void>.broadcast();

  Stream<void> get bluetoothChanges => _bluetoothChanges.stream;

  bool wasDisconnectedByTimer(String address) =>
      _timedDisconnectMac == address;
  Timer? _softwareTimer;
  int _softwareTimerRequest = 0;
  ({int seconds, DateTime deadline, bool bluetooth})? _softwareShutdown;
  bool _softwareBluetoothDisconnectFailed = false;

  ({int seconds, DateTime deadline, bool bluetooth})? get softwareShutdown =>
      _softwareShutdown;

  bool get softwareBluetoothDisconnectFailed => _softwareBluetoothDisconnectFailed;

  int _connectionGeneration = 0;
  Future<void> _timerOperation = Future.value();
  late StreamController<HeadphoneStatus> _controller;
  final List<int> _rxBuffer = [];
  final Map<int, Completer<Uint8List?>> _pending = {};
  Future<void> _rfcommOperation = Future.value();
  void Function(int, Uint8List)? _frameObserver;

  @override
  Stream<HeadphoneStatus> get statusStream => _controller.stream;

  @override
  HeadphoneStatus get currentStatus => _status;

  void _updateStatus(HeadphoneStatus newStatus) {
    if (_status.isConnected != newStatus.isConnected) {
      _connectionGeneration++;
      _rxBuffer.clear();
      for (final request in _pending.values) {
        request.complete(null);
      }
      _pending.clear();
    }
    if (_status.isConnected && !newStatus.isConnected) {
      _cancelSoftwareShutdown();
    }
    _status = newStatus;
    if (!_controller.isClosed) _controller.add(_status);
  }

  @override
  Future<void> connect(String macAddress) async {
    _connectedMac = macAddress.toUpperCase();
    if (_connectedMac == _timedDisconnectMac) _timedDisconnectMac = null;
    _softwareBluetoothDisconnectFailed = false;
    _updateStatus(_status.copyWith(isConnecting: true, isConnected: false));
    try {
      if (!await _hasConnectPermission(request: true)) {
        throw StateError('Bluetooth connection permission was denied');
      }
      await _methodChannel.invokeMethod('connect', {'mac': macAddress});
    } catch (e) {
      _updateStatus(HeadphoneStatus.disconnected().copyWith(error: e.toString()));
    }
  }

  @override
  Future<void> disconnect() async {
    _updateStatus(_status.copyWith(isConnecting: false, isConnected: false));
    try {
      await _methodChannel.invokeMethod('disconnect');
    } catch (_) {}
  }

  Future<bool> disconnectFromBluetooth() async {
    final mac = _connectedMac;
    if (mac == null) {
      await disconnect();
      return false;
    }

    try {
      if (await _AndroidFreeBuds(this).requestHostDisconnect() &&
          await _waitForAudioDisconnect(mac)) {
        return true;
      }

      if (await _audioDisconnected(mac)) return true;
      final associated = await _methodChannel.invokeMethod<bool>(
        'prepareBluetoothAssociation',
        {'mac': mac, 'action': 'disconnect'},
      );
      if (associated != true) return await _audioDisconnected(mac);
      final requested = await _methodChannel.invokeMethod<bool>(
        'disconnectBluetooth',
        {'mac': mac},
      );
      return requested == true
          ? await _waitForAudioDisconnect(mac)
          : await _audioDisconnected(mac);
    } on PlatformException {
      return _audioDisconnected(mac);
    } on MissingPluginException {
      return _audioDisconnected(mac);
    } finally {
      await disconnect();
    }
  }

  Future<bool> _audioDisconnected(String mac) async {
    final active = await getConnectedDevices();
    return active != null &&
        active.every((device) => device.macAddress.toUpperCase() != mac);
  }

  Future<bool> _waitForAudioDisconnect(String mac) async {
    final elapsed = Stopwatch()..start();
    do {
      if (await _audioDisconnected(mac)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    } while (elapsed.elapsed < const Duration(seconds: 3));
    return false;
  }

  Future<void> _ensurePermissions() async {
    final granted = await _methodChannel.invokeMethod<bool>('checkPermissions') ?? false;
    if (!granted) {
      await _methodChannel.invokeMethod<bool>('requestPermissions');
    }
  }

  Future<bool> _hasConnectPermission({required bool request}) async =>
      await _methodChannel.invokeMethod<bool>(
        request ? 'requestConnectPermission' : 'checkConnectPermission',
      ) ??
      false;

  @override
  Future<List<BluetoothDevice>?> getConnectedDevices({
    bool requestPermission = false,
    bool mediaOnly = false,
  }) async {
    try {
      if (!await _hasConnectPermission(request: requestPermission)) return null;
      final devices = await _methodChannel.invokeListMethod<Map>(
        'getConnectedDevices',
        {'mediaOnly': mediaOnly},
      );
      return devices?.map((device) => BluetoothDevice(
        name: device['name'] as String,
        macAddress: device['mac'] as String,
      )).toList();
    } catch (_) {
      return null;
    }
  }

  Future<bool> connectBluetoothAudio(
    String mac, {
    required bool interactive,
  }) async {
    try {
      if (interactive && !await _hasConnectPermission(request: true)) {
        return false;
      }
      Future<bool> hasAudio() async =>
          (await getConnectedDevices(mediaOnly: true))?.any(
            (device) => device.macAddress.toUpperCase() == mac.toUpperCase(),
          ) ??
          false;
      if (interactive && await hasAudio()) return true;
      if (interactive) {
        final associated = await _methodChannel.invokeMethod<bool>(
          'prepareBluetoothAssociation',
          {'mac': mac, 'action': 'connect'},
        );
        if (associated != true) return false;
      }
      final requested = await _methodChannel.invokeMethod<bool>(
        'connectBluetooth',
        {'mac': mac},
      );
      if (requested == true) {
        final elapsed = Stopwatch()..start();
        do {
          if (await hasAudio()) return true;
          await Future<void>.delayed(const Duration(milliseconds: 350));
        } while (elapsed.elapsed < const Duration(seconds: 4));
      }
    } on PlatformException {
      // The platform rejected the profile connection request.
    } on MissingPluginException {
      // No native profile connection support.
    }
    return false;
  }

  bool _isFreeBuds(String name) {
    final lower = name.toLowerCase();
    return lower.contains('huawei') ||
        lower.contains('freebuds') ||
        lower.contains('freebud') ||
        lower.contains('flypods') ||
        lower.contains('orange');
  }

  @override
  Future<List<BluetoothDevice>> getPairedDevices({
    bool requestPermission = true,
  }) async {
    try {
      if (!await _hasConnectPermission(request: requestPermission)) return [];
      final List<dynamic>? list = await _methodChannel
          .invokeMethod<List<dynamic>>('getPairedDevices');
      if (list == null) return [];
      return list
          .map((item) {
            final map = Map<String, dynamic>.from(item as Map);
            return BluetoothDevice(
              name: map['name'] as String? ?? 'Unknown',
              macAddress: map['mac'] as String? ?? '',
            );
          })
          .where((d) => _isFreeBuds(d.name))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<List<BluetoothDevice>> scanDevices() async {
    try {
      await _ensurePermissions();
      final List<dynamic>? list = await _methodChannel.invokeMethod<List<dynamic>>('startScan');
      final scanned = (list ?? [])
          .map((item) {
            final map = Map<String, dynamic>.from(item as Map);
            return BluetoothDevice(
              name: map['name'] as String? ?? 'Unknown',
              macAddress: map['mac'] as String? ?? '',
            );
          })
          .where((d) => _isFreeBuds(d.name))
          .toList();
      final paired = await getPairedDevices();
      final seen = <String>{};
      final combined = <BluetoothDevice>[];
      for (final d in [...paired, ...scanned]) {
        if (d.macAddress.isNotEmpty && seen.add(d.macAddress)) {
          combined.add(d);
        }
      }
      return combined.isNotEmpty ? combined : paired;
    } catch (_) {
      return await getPairedDevices();
    }
  }

  // --- FreeBuds framing ---

  int _crc16(List<int> data) {
    var crc = 0;
    for (final b in data) {
      final idx = ((crc >> 8) ^ b) & 0xFF;
      crc = (_crcTable[idx] ^ (crc << 8)) & 0xFFFF;
    }
    return crc;
  }

  Uint8List _buildFrame(List<int> payload) {
    final frameLen = payload.length + 1;
    final frame = Uint8List(4 + payload.length + 2);
    frame[0] = 0x5A;
    frame[1] = (frameLen >> 8) & 0xFF;
    frame[2] = frameLen & 0xFF;
    frame[3] = 0x00;
    frame.setRange(4, 4 + payload.length, payload);
    final crc = _crc16(frame.sublist(0, 4 + payload.length));
    frame[4 + payload.length] = (crc >> 8) & 0xFF;
    frame[5 + payload.length] = crc & 0xFF;
    return frame;
  }

  void _handleIncomingBytes(List<int> bytes) {
    _rxBuffer.addAll(bytes);
    while (_rxBuffer.length >= 4) {
      final start = _rxBuffer.indexOf(0x5A);
      if (start < 0) {
        _rxBuffer.clear();
        return;
      }
      if (start > 0) _rxBuffer.removeRange(0, start);
      if (_rxBuffer.length < 4) return;
      final frameLen = (_rxBuffer[1] << 8) | _rxBuffer[2];
      if (frameLen < 3) {
        _rxBuffer.removeAt(0);
        continue;
      }
      final total = 4 + (frameLen - 1) + 2;
      if (_rxBuffer.length < total) return;
      final frame = _rxBuffer.sublist(0, total);
      _rxBuffer.removeRange(0, total);
      final crcRecv = (frame[total - 2] << 8) | frame[total - 1];
      if (crcRecv != _crc16(frame.sublist(0, total - 2))) continue;
      final payloadLen = frameLen - 1;
      if (payloadLen < 2) continue;
      final payload = Uint8List.fromList(frame.sublist(4, 4 + payloadLen));
      final key = (payload[0] << 8) | payload[1];
      final data = Uint8List.sublistView(payload, 2);
      if (_status.isConnected && (key == 0x0108 || key == 0x0127)) {
        _applyBattery(data);
      }
      _frameObserver?.call(key, data);
      final completer = _pending.remove(key);
      if (completer != null && !completer.isCompleted) {
        completer.complete(data);
      }
    }
  }

  Future<T> _runRfcomm<T>(Future<T> Function() operation) async {
    final previous = _rfcommOperation;
    final done = Completer<void>();
    _rfcommOperation = done.future;
    try {
      await previous;
      return await operation();
    } finally {
      done.complete();
    }
  }

  Future<Uint8List?> _send(List<int> payload, int svc, int cmd) {
    final generation = _connectionGeneration;
    return _runRfcomm(() async {
      if (!_status.isConnected || generation != _connectionGeneration) return null;
      return _sendFrame(payload, svc, cmd);
    });
  }

  Future<Uint8List?> _sendFrame(List<int> payload, int svc, int cmd) async {
    final key = (svc << 8) | cmd;
    final completer = Completer<Uint8List?>();
    _pending[key] = completer;
    try {
      await _methodChannel.invokeMethod('write', {'bytes': _buildFrame(payload)});
      return await completer.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (identical(_pending[key], completer)) _pending.remove(key);
    }
  }

  static Map<int, Uint8List> _tlv(Uint8List data) {
    final result = <int, Uint8List>{};
    var pos = 0;
    while (pos < data.length - 1) {
      final tag = data[pos];
      final length = data[pos + 1];
      if (pos + 2 + length > data.length) break;
      result[tag] = Uint8List.fromList(data.sublist(pos + 2, pos + 2 + length));
      pos += 2 + length;
    }
    return result;
  }

  static bool? _boolValue(Uint8List? data) {
    if (data == null) return null;
    if (data.length >= 6 && data[0] == 0x7F && data[1] == 0x04) return null;
    for (final v in _tlv(data).values) {
      if (v.length == 1 && (v[0] == 0 || v[0] == 1)) return v[0] == 1;
    }
    if (data.isNotEmpty && (data[0] == 0 || data[0] == 1)) return data[0] == 1;
    return null;
  }

  Future<T> _runTimerOperation<T>(Future<T> Function() operation) async {
    final previous = _timerOperation;
    final complete = Completer<void>();
    _timerOperation = complete.future;
    await previous;
    try {
      return await operation();
    } finally {
      complete.complete();
    }
  }

  void _markAutoShutdownUnsupported() {
    final model = _status.modelInfo!;
    final capabilities = model['capabilities'] as Map<String, dynamic>;
    _updateStatus(_status.copyWith(modelInfo: {
      ...model,
      'capabilities': {...capabilities, 'has_auto_shutdown': false},
    }));
  }

  static int? _responseStatus(Map<int, Uint8List> fields) {
    final result = fields[0x7F];
    if (result == null || result.length != 4) return null;
    return ByteData.sublistView(result).getUint32(0);
  }

  Future<int?> _readAutoShutdownSeconds(int generation) async {
    final response = await _send(_dormantCmd, 0x2B, 0x48);
    if (response == null || generation != _connectionGeneration) return null;

    final fields = _tlv(response);
    if (_responseStatus(fields) == _commandUnsupported) {
      _markAutoShutdownUnsupported();
    }
    final value = fields[1];
    if (fields.containsKey(0x7F) ||
        value == null ||
        value.isEmpty ||
        value.length > 4) {
      return null;
    }

    var seconds = 0;
    for (final byte in value) {
      seconds = (seconds << 8) | byte;
    }
    return seconds;
  }

  void _applyBattery(Uint8List data) {
    final fields = _tlv(data);
    final values = fields[2];
    if (values == null) return;
    int? percentage(int index) =>
        index < values.length && values[index] <= 100 ? values[index] : null;
    final left = percentage(0);
    final right = percentage(1);
    final batteryCase = percentage(2);
    final percent = left ?? right;
    if ((left == null || left == _status.batteryLeft) &&
        (right == null || right == _status.batteryRight) &&
        (batteryCase == null || batteryCase == _status.batteryCase) &&
        (percent == null || percent == _status.batteryPercent)) {
      return;
    }
    _updateStatus(_status.copyWith(
      batteryLeft: left,
      batteryRight: right,
      batteryCase: batteryCase,
      batteryPercent: percent,
    ));
  }

  Future<void> _queryStatus() async {
    final generation = _connectionGeneration;
    await _send(_batteryCmd, 0x01, 0x08);
    if (generation != _connectionGeneration) return;

    String? colorId;
    String? deviceName;
    final version = await _send(_versionCmd, 0x01, 0x07);
    if (generation != _connectionGeneration) return;
    if (version != null) {
      final vtlv = _tlv(version);
      final rawSub = vtlv[25];
      if (rawSub != null && rawSub.isNotEmpty) {
        colorId = rawSub[0].toRadixString(16).padLeft(2, '0').toUpperCase();
      }
      final rawOta = vtlv[15];
      final ota = rawOta == null ? '' : utf8.decode(rawOta, allowMalformed: true).toUpperCase();
      final rawModel = vtlv[3];
      final model = rawModel == null ? '' : utf8.decode(rawModel, allowMalformed: true).toUpperCase();
      final is5i = ['01', '07', '0C'].contains(colorId) ||
          ota.contains('BTFT0014') ||
          ota.contains('00013D') ||
          model.contains('T0012');
      deviceName = is5i ? 'Huawei FreeBuds 5i' : 'Huawei FreeBuds';
    }

    _updateStatus(_status.copyWith(
      deviceName: deviceName,
      modelInfo: {
        'key': 'FREEBUDS_5I',
        'name': 'Huawei FreeBuds 5i',
        'sub_model_id': ?colorId,
        'capabilities': {
          'has_anc': true,
          'has_anc_levels': true,
          'has_spatial_audio': false,
          'has_ldac': false,
          'has_tws_battery': true,
          'has_gestures': true,
          'has_wear_detection': true,
          'has_auto_shutdown': true,
          'has_anti_leak': false,
          'eq_type': 'standard',
        },
      },
    ));

    final seconds = await _runTimerOperation<int?>(() async {
      if (generation != _connectionGeneration) return null;
      return _readAutoShutdownSeconds(generation);
    });
    if (generation != _connectionGeneration) return;

    if (seconds != null) {
      _updateStatus(_status.copyWith(autoShutdownSeconds: seconds));
    }

    final (mode, level) = await _readAnc();
    if (generation != _connectionGeneration) return;
    final dynamicReply = await _send([0x2B, 0x2B, 3, 0], 0x2B, 0x2B);
    if (generation != _connectionGeneration) return;
    final adaptive = dynamicReply != null && _tlv(dynamicReply)[1]?.firstOrNull == 1;
    _updateStatus(_status.copyWith(
      modelInfo: {
        ...?_status.modelInfo,
        'adaptive_anc': adaptive || (mode == 1 && level == 3),
      },
      ancMode: switch (mode) {
        0 => 'Normal (Off)',
        1 => level == 3 ? 'Adaptive Auto-ANC' : 'ANC On',
        2 => 'Transparency',
        _ => null,
      },
      ancIntensity: mode == 1 ? {2: 0, 0: 1, 1: 2}[level] : null,
    ));

    final eq = await _send(_eqCmd, 0x2B, 0x4A);
    if (generation != _connectionGeneration) return;
    if (eq != null && _statusCode(eq) == null) {
      final fields = _tlv(eq);
      final modes = fields[3];
      final supported = fields[1]?.firstOrNull;
      final mode = fields[2]?.firstOrNull;
      _updateStatus(_status.copyWith(
        eqPreset: freeBudsEqPresets[mode],
        modelInfo: {
          ...?_status.modelInfo,
          if (supported == 0) 'eq_modes': <int>[]
          else if (modes != null) 'eq_modes': modes.toList(),
        },
      ));
    }

    final featureValues = <String, bool?>{};
    for (final entry in _featureGets.entries) {
      final data = await _send(entry.value, 0x2B, entry.value[1]);
      featureValues[entry.key] = _boolValue(data);
      if (generation != _connectionGeneration) return;
    }
    _updateStatus(_status.copyWith(
      gameMode: featureValues['glat'] ?? _status.gameMode,
      multipoint: featureValues['dual'] ?? _status.multipoint,
      ldac: featureValues['hd'] ?? _status.ldac,
      windNoise: featureValues['wind'] ?? _status.windNoise,
      wearDetection: featureValues['wear'] ?? _status.wearDetection,
      antiLeak: false,
      spatialAudioMode: 'Off',
      spatialScene: 'Music',
    ));

    final gestures = <String, dynamic>{};
    var typeIndex = 1;
    for (final entry in _gestureGets.entries) {
      final data = await _send(entry.value, entry.value[0], entry.value[1]);
      if (generation != _connectionGeneration) return;
      if (data != null) {
        final tlv = _tlv(data);
        final left = tlv[1];
        final right = tlv[2];
        if (left != null && left.isNotEmpty || right != null && right.isNotEmpty) {
          gestures['$typeIndex'] = {
            if (left != null && left.isNotEmpty) 'left_func': left[0],
            if (right != null && right.isNotEmpty) 'right_func': right[0],
          };
        }
      }
      typeIndex++;
    }
    if (gestures.isNotEmpty) {
      _updateStatus(_status.copyWith(gestures: gestures));
    }
  }

  Future<(int?, int?)> _readAnc() async {
    final generation = _connectionGeneration;
    for (final payload in [[0x2B, 0x2A, 1, 0], _ancCmd, [0x2B, 0x07, 1, 0]]) {
      if (generation != _connectionGeneration) break;
      final reply = await _send(payload, 0x2B, payload[1]);
      if (reply == null || _statusCode(reply) != null) continue;
      final fields = _tlv(reply);
      final state = fields[1];
      if (state == null || state.isEmpty || state.last > 2) continue;
      final mode = state.last;
      final level = mode != 1 ? null : switch (payload[1]) {
        0x07 => fields[2]?.firstOrNull,
        _ => state.length == 2 ? state.first : null,
      };
      return (mode, level);
    }
    return (null, null);
  }

  Future<void> _writeAnc(int mode, int level) async {
    final generation = _connectionGeneration;
    final reply = await _send([0x2B, 0x04, 1, 2, mode, level], 0x2B, 0x04);
    final status = reply == null ? null : _statusCode(reply) ?? _tlv(reply)[2]?.firstOrNull;
    if (generation != _connectionGeneration ||
        (status != 0 && status != _commandSucceeded)) {
      _unconfirmed();
    }
  }

  Future<bool?> _setFeature(String name, bool enabled) async {
    final cmd = _featureSetCmds[name];
    if (cmd == null) return null;
    final data = await _send([0x2B, cmd, 0x01, 0x01, enabled ? 1 : 0], 0x2B, cmd);
    return _boolValue(data);
  }

  @override
  Future<void> setAncMode(int mode) async {
    final fbMode = mode == 4 ? 1 : (mode == 1 ? 1 : (mode == 2 ? 2 : 0));
    if (mode == 4 && _status.modelInfo?['adaptive_anc'] != true) {
      throw StateError('Adaptive ANC is unavailable on the earbuds');
    }
    final level = mode == 4 ? 3 : (fbMode == 0 ? 0 : 0xFF);
    await _writeAnc(fbMode, level);
    _updateStatus(_status.copyWith(
      ancMode: mode == 4
          ? 'Adaptive Auto-ANC'
          : (fbMode == 0 ? 'Normal (Off)' : (fbMode == 2 ? 'Transparency' : 'ANC On')),
    ));
  }

  @override
  Future<void> setAncLevel(int level) async {
    // App: 0=High, 1=Medium, 2=Low -> FreeBuds: 2=Ultra, 0=General, 1=Cozy.
    final fbLevel = {0: 2, 1: 0, 2: 1}[level] ?? 0;
    await _writeAnc(1, fbLevel);
    _updateStatus(_status.copyWith(ancIntensity: level));
  }

  @override
  Future<void> setGameMode(bool enabled) async {
    await _setFeature('glat', enabled);
    _updateStatus(_status.copyWith(gameMode: enabled));
  }

  @override
  Future<void> setWindNoise(bool enabled) async {
    await _setFeature('wind', enabled);
    _updateStatus(_status.copyWith(windNoise: enabled));
  }

  @override
  Future<void> setMultipoint(bool enabled) async {
    await _setFeature('dual', enabled);
    _updateStatus(_status.copyWith(multipoint: enabled));
  }

  @override
  Future<void> setLdac(bool enabled) async {
    await _setFeature('hd', enabled);
    _updateStatus(_status.copyWith(ldac: enabled));
  }

  @override
  Future<void> setWearDetection(bool enabled) async {
    await _setFeature('wear', enabled);
    _updateStatus(_status.copyWith(wearDetection: enabled));
  }

  @override
  Future<void> setAntiLeak(bool enabled) async {
    _updateStatus(_status.copyWith(antiLeak: enabled));
  }

  @override
  Future<void> setAutoShutdown(int timerVal) {
    return setAutoShutdownSeconds(
      {1: 1800, 2: 3600, 6: 10800, 10: 18000, 255: 0}[timerVal] ?? 0,
    );
  }

  Future<void> setAutoShutdownSeconds(int seconds) async {
    RangeError.checkValueInInterval(seconds, 0, 0xFFFFFFFF, 'seconds');
    final generation = _connectionGeneration;
    final request = ++_softwareTimerRequest;
    await _runTimerOperation(
      () => _writeAutoShutdownSeconds(seconds, generation),
    );
    if (generation == _connectionGeneration &&
        request == _softwareTimerRequest &&
        (!_status.hasAutoShutdown || _softwareShutdown != null)) {
      await _setSoftwareShutdown(seconds, generation, request);
    }
  }

  void _cancelSoftwareShutdown() {
    _softwareTimerRequest++;
    _softwareTimer?.cancel();
    _softwareTimer = null;
    _softwareShutdown = null;
  }

  Future<void> _setSoftwareShutdown(
    int seconds,
    int generation,
    int request,
  ) async {
    if (seconds == 0) {
      _cancelSoftwareShutdown();
      _updateStatus(_status);
      return;
    }

    final mac = _connectedMac;
    var bluetooth = false;
    if (mac != null) {
      try {
        bluetooth =
            await _methodChannel.invokeMethod<bool>(
              'prepareBluetoothAssociation',
              {'mac': mac},
            ) ??
            false;
      } on PlatformException {
        // Closing the control connection is available without an association.
      } on MissingPluginException {
        // Older native builds only have the control disconnect method.
      }
    }
    if (generation != _connectionGeneration || request != _softwareTimerRequest) {
      return;
    }

    final delay = Duration(seconds: seconds);
    _softwareTimer?.cancel();
    _softwareShutdown = (
      seconds: seconds,
      deadline: DateTime.now().add(delay),
      bluetooth: bluetooth,
    );
    _softwareTimer = Timer(delay, () async {
      if (generation != _connectionGeneration) return;
      _timedDisconnectMac = mac;
      await disconnect();
      if (!bluetooth ||
          mac == null ||
          _status.isConnected ||
          _status.isConnecting) {
        return;
      }
      final disconnectedGeneration = _connectionGeneration;
      var requested = false;
      try {
        requested =
            await _methodChannel.invokeMethod<bool>('disconnectBluetooth', {
              'mac': mac,
            }) ??
            false;
      } on PlatformException {
        // The control socket has already been closed.
      } on MissingPluginException {
        // The control socket has already been closed.
      }
      if (!requested &&
          disconnectedGeneration == _connectionGeneration &&
          !_status.isConnected &&
          !_status.isConnecting &&
          !_controller.isClosed) {
        _softwareBluetoothDisconnectFailed = true;
        _updateStatus(_status);
      }
    });
    _updateStatus(_status);
  }

  Future<void> _writeAutoShutdownSeconds(int seconds, int generation) async {
    if (generation != _connectionGeneration || !_status.isConnected) {
      throw StateError('Auto shutdown is unavailable');
    }
    if (!_status.hasAutoShutdown || _softwareShutdown != null) return;
    final payload = <int>[0x2B, 0x47, 0x01, 0x01, 0x00, 0x01, 0x04];
    for (var shift = 24; shift >= 0; shift -= 8) {
      payload.add((seconds >> shift) & 0xFF);
    }

    final response = await _send(payload, 0x2B, 0x47);
    if (generation != _connectionGeneration) {
      throw StateError('Headphones disconnected');
    }
    final fields = response == null ? const <int, Uint8List>{} : _tlv(response);
    final result = _responseStatus(fields);
    if (result == _commandUnsupported) {
      _markAutoShutdownUnsupported();
      return;
    }
    if (fields.containsKey(0x7F) && result != _commandSucceeded) {
      throw StateError('Headphones rejected the timer');
    }

    final applied = await _readAutoShutdownSeconds(generation);
    if (generation != _connectionGeneration) {
      throw StateError('Headphones disconnected');
    }
    if (!_status.hasAutoShutdown) return;
    if (applied == null && result == null) {
      throw StateError('Could not confirm the auto shutdown timer');
    }
    _updateStatus(_status.copyWith(autoShutdownSeconds: applied ?? seconds));
    if (applied != null && applied != seconds) {
      throw StateError('Headphones reported a different timer');
    }
  }

  @override
  Future<void> setSpatialAudio(String mode) async {
    _updateStatus(_status.copyWith(spatialAudioMode: mode));
  }

  @override
  Future<void> setSpatialScene(int sceneIdx) async {
    _updateStatus(_status.copyWith(
      spatialScene: ['Music', 'Sport', 'Movie'][sceneIdx.clamp(0, 2)],
    ));
  }

  @override
  Future<void> setEqPreset(int presetIdx) async {
    final mode = {0: 1, 5: 2, 9: 9}[presetIdx] ?? 1;
    await runFreeBudsCommand(FreeBudsCommand.eq, {'mode': mode});
  }

  @override
  Future<void> setCustomEq(List<double> gains) async {
    await setEqPreset(0);
  }

  @override
  Future<void> setGesture(int gestureType, int leftFunc, int rightFunc) async {
    final key = {1: 'double_click', 2: 'triple_click', 3: 'long_press'}[gestureType] ?? 'double_click';
    final header = _gestureSetHeaders[key]!;
    const appActions = {0: 0, 1: 1, 2: 7, 3: 2, 255: 255};
    final payload = <int>[...header];
    if (leftFunc != 255) {
      payload.addAll([0x01, 0x01, appActions[leftFunc] ?? 255]);
    }
    if (rightFunc != 255) {
      payload.addAll([0x02, 0x01, appActions[rightFunc] ?? 255]);
    }
    await _send(payload, payload[0], payload[1]);
    await _queryStatus();
  }

  @override
  Future<void> renameDevice(String newName) async {
    _updateStatus(_status.copyWith(deviceName: newName));
  }

  @override
  Future<void> findDevice(bool play) async {
    for (final side in ['left', 'right']) {
      await runFreeBudsCommand(FreeBudsCommand.locator, {'side': side, 'ring': play});
    }
  }

  @override
  Future<Map<String, dynamic>> runFreeBudsCommand(
    FreeBudsCommand command, [
    Map<String, Object> arguments = const {},
  ]) => _AndroidFreeBuds(this).run(command, arguments);

  @override
  Future<void> refreshStatus() async {
    await _queryStatus();
  }

  @override
  void dispose() {
    _eventSubscription.cancel();
    _bluetoothChanges.close();
    _cancelSoftwareShutdown();
    disconnect();
    _controller.close();
  }
}
