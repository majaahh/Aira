part of 'android_service.dart';

const _features = {
  'venh': (0x42, 0x41, 1),
  'hd': (0xA3, 0xA2, 1),
  'silent': (0x70, 0x6F, 1),
  'health': (0x61, 0x60, 0),
  'greet': (0x0F, 0x0E, 0),
  'saving': (0x1D, 0x1C, 0),
  'volume': (0x23, 0x22, 0),
  'translate': (0x4D, 0x4C, 0),
  'hd_voice': (0x46, 0x45, 1),
  'ear_balance': (0x9A, 0x99, 0),
};

const _gestures = {
  'double_click': (0x01, 0x20, 0x1F, {0, 1, 2, 7, 255}),
  'triple_click': (0x01, 0x26, 0x25, {2, 7, 255}),
  'long_press': (0x2B, 0x17, 0x16, {10, 14, 15, 255}),
  'slide': (0x2B, 0x1F, 0x1E, {0, 255}),
};

int? _statusCode(Uint8List data) {
  final status = AndroidHeadphoneService._tlv(data)[0x7F];
  if (status == null || status.length != 4) return null;
  return ByteData.sublistView(status).getUint32(0);
}

String _deviceText(Uint8List bytes) =>
    utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '').trim();

Never _unconfirmed() =>
    throw StateError('The earbuds did not confirm the change');

void _requireAck(Uint8List? response, {bool acceptZero = false}) {
  final status = response == null ? null : _statusCode(response);
  if (status != AndroidHeadphoneService._commandSucceeded &&
      !(acceptZero && status == 0)) {
    _unconfirmed();
  }
}

void _requireNoRejection(Uint8List? response) {
  final status = response == null ? null : _statusCode(response);
  if (status != null && status != AndroidHeadphoneService._commandSucceeded) {
    _unconfirmed();
  }
}

class _AndroidFreeBuds {
  _AndroidFreeBuds(this.service) : generation = service._connectionGeneration;

  final AndroidHeadphoneService service;
  final int generation;

  bool get _connected =>
      service._status.isConnected &&
      generation == service._connectionGeneration;

  void _checkConnection() {
    if (!_connected) throw StateError('FreeBuds disconnected');
  }

  Future<Uint8List?> _send(List<int> payload, int serviceId, int command) {
    _checkConnection();
    return service._sendFrame(payload, serviceId, command);
  }

  Future<Map<String, dynamic>> run(
    FreeBudsCommand command,
    Map<String, Object> arguments,
  ) async {
    _checkConnection();
    if (command == FreeBudsCommand.fit) {
      await AndroidHeadphoneService._methodChannel.invokeMethod(
        'prepareFitAudio',
        {'mac': service._connectedMac},
      );
    }
    return service._runRfcomm(() async {
      _checkConnection();
      final result = await switch (command) {
        FreeBudsCommand.controls => _readFreeBudsControls(
          arguments['section'] as String,
        ),
        FreeBudsCommand.information => _freeBudsInformation(),
        FreeBudsCommand.devices => _bondedFreeBudsDevices(),
        FreeBudsCommand.locator => _setLocator(
          arguments['side'] as String,
          arguments['ring'] as bool,
        ),
        FreeBudsCommand.gesture => _changeFreeBudsGesture(
          arguments['key'] as String,
          arguments['side'] as String,
          arguments['action'] as int,
        ),
        FreeBudsCommand.noiseCycle => _changeNoiseCycle(
          arguments['side'] as String,
          arguments['cycle'] as int,
        ),
        FreeBudsCommand.feature => _changeExtraFeature(
          arguments['key'] as String,
          arguments['enabled'] as bool,
        ),
        FreeBudsCommand.language => _changePromptLanguage(
          arguments['code'] as String,
        ),
        FreeBudsCommand.device => _changeBondedDevice(arguments),
        FreeBudsCommand.eq => _changeFreeBudsEq(arguments['mode'] as int),
        FreeBudsCommand.fit => _runFreeBudsFit(),
      };
      _checkConnection();
      return result;
    });
  }

  Future<Map<int, Uint8List>> _readFields(List<int> payload) async {
    final response = await _send(payload, payload[0], payload[1]);
    if (response == null || _statusCode(response) != null) return {};
    return AndroidHeadphoneService._tlv(response);
  }

  Future<bool?> _readBoolean(List<int> payload) async {
    final fields = await _readFields(payload);
    for (final value in fields.values) {
      final byte = _byte(value);
      if (byte == 0 || byte == 1) return byte == 1;
    }
    return null;
  }

  Future<Map<String, dynamic>> _readFreeBudsControls(String section) async {
    if (section == 'wear') return _readWear();
    if (section == 'locator') {
      return {
        'locator': {
          'left': await _readLocator(0),
          'right': await _readLocator(1),
        },
      };
    }
    if (section == 'gestures') {
      final gestures = <String, Map<String, dynamic>>{};
      for (final key in _gestures.keys) {
        final state = await _readFreeBudsGesture(key);
        if (state.isNotEmpty) gestures[key] = state;
      }
      return {'gestures': gestures, 'cycle': await _readNoiseCycle()};
    }
    if (section != 'preferences') throw ArgumentError.value(section);
    final features = <String, bool>{};
    for (final entry in _features.entries) {
      final value = await _readBoolean([
        0x2B,
        entry.value.$1,
        1,
        entry.value.$3,
      ]);
      if (value != null) features[entry.key] = value;
    }
    return {'features': features, 'language': await _readPromptLanguage()};
  }

  Future<Map<String, dynamic>> _readFreeBudsGesture(String key) async {
    final (service, get, _, actions) = _gestures[key]!;
    final fields = await _readFields([service, get, 1, 0, 2, 0, 3, 0]);
    final global = key == 'slide';
    final hasCalls = key == 'double_click' || key == 'long_press';
    final left = _byte(fields[1]);
    final right = _byte(fields[2]);
    final call = _byte(fields[4]);
    final supported = fields[3];
    return {
      (global ? 'global' : 'left'): ?left,
      if (!global) 'right': ?right,
      if (hasCalls && call != null) 'call_action': call,
      if (hasCalls)
        'call_supported': ?fields[6]
            ?.where((value) => value == 0 || value == 255)
            .toList(),
      if (supported != null)
        'supported': actions
            .where(
              (action) =>
                  supported.contains(action) ||
                  key == 'long_press' && action == 255,
            )
            .toList(),
    };
  }

  Future<Map<String, dynamic>> _changeFreeBudsGesture(
    String key,
    String side,
    int action,
  ) async {
    final state = await _readFreeBudsGesture(key);
    final field = side == 'call' ? 'call_action' : side;
    final options = state[side == 'call' ? 'call_supported' : 'supported'];
    if (!state.containsKey(field) ||
        options is! List ||
        !options.contains(action)) {
      throw StateError('This gesture action is unavailable on the earbuds');
    }
    final (service, _, set, _) = _gestures[key]!;
    final payload = switch (side) {
      'left' => [1, 1, action],
      'right' => [2, 1, action],
      'call' => [4, 1, action],
      'global' => [1, 1, action, 2, 2, action],
      _ => throw ArgumentError.value(side),
    };
    final response = await _send([service, set, ...payload], service, set);
    _requireNoRejection(response);
    final report = response == null
        ? null
        : _byte(AndroidHeadphoneService._tlv(response)[side == 'call' ? 6 : 3]);
    if (report == 1 || report == 3) _unconfirmed();
    final observed = await _readFreeBudsGesture(key);
    if (observed[field] != action) _unconfirmed();
    return observed;
  }

  Future<Map<String, dynamic>> _readNoiseCycle() async {
    final fields = await _readFields([0x2B, 0x19, 1, 0, 2, 0]);
    return {
      if (_byte(fields[1]) case final int left) 'left': left,
      if (_byte(fields[2]) case final int right) 'right': right,
      if (fields[3] case final Uint8List options) 'supported': options.toList(),
    };
  }

  Future<Map<String, dynamic>> _changeNoiseCycle(String side, int cycle) async {
    final state = await _readNoiseCycle();
    final options = state['supported'];
    if (!state.containsKey(side) ||
        cycle < 1 ||
        cycle > 4 ||
        options is! List ||
        !options.contains(cycle)) {
      throw StateError('This noise control cycle is unavailable');
    }
    final response = await _send(
      [0x2B, 0x18, _sideIndex(side) + 1, 1, cycle],
      0x2B,
      0x18,
    );
    _requireNoRejection(response);
    final observed = await _readNoiseCycle();
    if (observed[side] != cycle) _unconfirmed();
    return observed;
  }

  Future<Map<String, dynamic>> _readPromptLanguage() async {
    // The stock FreeBuds language picker queries the non-unit form first.
    final fields = await _readFields([0x0C, 0x02, 1, 0, 3, 0]);
    var current = fields[1] == null ? '' : _deviceText(fields[1]!);
    var options = fields[3];
    if (current.isEmpty || options == null || options.isEmpty) {
      final unitFields = await _readFields([0x0C, 0x02, 1, 0, 2, 0, 3, 0]);
      if (current.isEmpty && unitFields[1] != null) {
        current = _deviceText(unitFields[1]!);
      }
      if (options == null || options.isEmpty) options = unitFields[3];
    }
    final supported = options == null
        ? <String>[]
        : _deviceText(options)
              .split(',')
              .map((code) => code.trim())
              .where((code) => code.isNotEmpty)
              .toList();
    if (current.isEmpty) {
      // Huawei's prompt-pack query returns the installed package name in tag 1.
      final packFields = await _readFields([0x2B, 0x51]);
      if (packFields[1] case final Uint8List name) {
        final pack = _deviceText(name).toLowerCase().replaceAll('_', '-');
        final matches = supported.where((code) {
          final locale = code.toLowerCase().replaceAll('_', '-');
          if (locale == pack) return true;
          if (!locale.contains('-')) return false;
          return RegExp(
            '(?:^|[^a-z0-9])${RegExp.escape(locale)}'
            r'(?:$|[^a-z0-9])',
          ).hasMatch(pack);
        }).toList();
        if (matches.length == 1) current = matches.single;
        if (current.isEmpty &&
            RegExp(r'^[a-z]{2,3}-[a-z]{2}$').hasMatch(pack)) {
          current = pack;
        }
      }
    }
    return {
      if (current.isNotEmpty) 'current': current,
      if (supported.isNotEmpty) 'supported': supported,
    };
  }

  Future<Map<String, dynamic>> _changePromptLanguage(String code) async {
    final options = (await _readPromptLanguage())['supported'];
    if (options is! List ||
        !options.contains(code) ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,16}$').hasMatch(code)) {
      throw StateError('This prompt language is unavailable');
    }
    final response = await _send(
      [0x0C, 0x01, 1, code.length, ...ascii.encode(code)],
      0x0C,
      0x01,
    );
    _requireAck(response);
    return {'current': code, ...await _readPromptLanguage()};
  }

  Future<Map<String, dynamic>> _changeExtraFeature(
    String key,
    bool enabled,
  ) async {
    final (get, set, length) = _features[key]!;
    final query = [0x2B, get, 1, length];
    if (await _readBoolean(query) == null) {
      throw StateError('This option is unavailable on the earbuds');
    }
    final response = await _send([0x2B, set, 1, 1, enabled ? 1 : 0], 0x2B, set);
    _requireNoRejection(response);
    if (await _readBoolean(query) != enabled) _unconfirmed();
    return {'enabled': enabled};
  }

  static int? _byte(Uint8List? value) =>
      value?.length == 1 ? value!.first : null;

  static int _sideIndex(String side) => switch (side) {
    'left' => 0,
    'right' => 1,
    _ => throw ArgumentError.value(side),
  };

  Future<Map<int, Uint8List>> _wearingStatus() =>
      _readFields([0x2B, 0x25, 1, 0, 2, 0]);

  Future<Map<String, dynamic>?> _readLocator(int index) async {
    final fields = await _readFields([0x2B, 0x5E, 1, 1, index]);
    final value = fields[2];
    if (value == null ||
        value.length != 2 ||
        value[0] != index ||
        value[1] > 1) {
      return null;
    }
    return {'ringing': value[1] == 0};
  }

  Future<Map<String, dynamic>> _readWear() async {
    final fields = await _wearingStatus();
    return {
      for (final (side, tag) in [('left', 1), ('right', 2)])
        '${side}_in': switch (_byte(fields[tag])) {
          0 => false,
          1 => true,
          _ => null,
        },
    };
  }

  Future<Map<String, dynamic>> _setLocator(String side, bool ring) async {
    final index = _sideIndex(side);
    if (ring) {
      final wear = await _readWear();
      if (wear['left_in'] != false || wear['right_in'] != false) {
        throw StateError('Take both earbuds out before ringing them');
      }
    }
    final response = await _send(
      [0x2B, 0x5D, 1, 2, index, ring ? 0 : 1],
      0x2B,
      0x5D,
    );
    _requireNoRejection(response);
    final observed = await _readLocator(index);
    if (observed == null || observed['ringing'] != ring) _unconfirmed();
    return observed;
  }

  Future<Map<String, dynamic>> _changeFreeBudsEq(int mode) async {
    final name = freeBudsEqPresets[mode];
    final current = await _readFields(AndroidHeadphoneService._eqCmd);
    final supported = current[3];
    if (name == null ||
        _byte(current[1]) == 0 ||
        supported != null && !supported.contains(mode)) {
      throw StateError('This EQ preset is unavailable on the earbuds');
    }
    final response = await _send([0x2B, 0x49, 1, 1, mode], 0x2B, 0x49);
    _requireAck(response, acceptZero: true);
    _checkConnection();
    service._updateStatus(service._status.copyWith(eqPreset: name));
    return {'mode_name': name};
  }

  Future<Map<String, dynamic>> _freeBudsInformation() async {
    final version = await _readFields(AndroidHeadphoneService._versionCmd);
    final dynamicAnc = await _readFields([0x2B, 0x2B, 3, 0]);
    final dynamicSupport = _byte(dynamicAnc[1]);
    return {
      'version': {
        for (final entry in {
          1: 'bluetooth_version',
          3: 'model',
          7: 'firmware',
          9: 'serial',
          15: 'ota_package',
          24: 'bud_serials',
        }.entries)
          if (version[entry.key] case final Uint8List value)
            entry.value: _deviceText(value),
      },
      if (dynamicSupport == 0 || dynamicSupport == 1)
        'dynamic': dynamicSupport == 1,
    };
  }

  Future<Map<String, dynamic>> _bondedFreeBudsDevices() async {
    final devices = <String, Map<String, dynamic>>{};
    final reports = <Map<int, Uint8List>>[];
    service._frameObserver = (key, data) {
      final fields = AndroidHeadphoneService._tlv(data);
      if (key == 0x2B31) {
        final address = fields[4];
        if (address == null || address.length != 6) return;
        final mac = _macAddress(address);
        final state = _byte(fields[5]);
        devices[mac] = {
          'addr': mac,
          'index': _byte(fields[3]),
          if (fields[9] case final Uint8List name) 'name': _deviceText(name),
          if (state != null) 'conn_state': state & 1,
          if (_byte(fields[6]) case final int type) 'type': type,
          if (_byte(fields[7]) case final int primary) 'primary': primary,
          if (_byte(fields[8]) case final int reconnect)
            'back_conn_permit': reconnect,
          if (_byte(fields[10]) case final int autoSwitch)
            'allow_audio_auto_switch': autoSwitch == 1,
        };
      } else if (key == 0x2B36) {
        reports.add(fields);
      }
    };
    try {
      final response = await _send([0x2B, 0x31, 1, 0], 0x2B, 0x31);
      final status = response == null ? null : _statusCode(response);
      if (response != null &&
          (status == null ||
              status == AndroidHeadphoneService._commandSucceeded)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } finally {
      service._frameObserver = null;
    }
    for (final report in reports) {
      for (final tag in [5, 6, 8]) {
        final value = report[tag];
        if (value == null || value.length != 7) continue;
        final device = devices[_macAddress(value.take(6))];
        if (device == null) continue;
        if (tag == 5) device['conn_state'] = value[6] & 1;
        if (tag == 6) device['back_conn_permit'] = value[6];
        if (tag == 8) device['allow_audio_auto_switch'] = value[6] == 1;
      }
    }
    return {
      'devices': devices.values.toList()
        ..sort(
          (left, right) => (left['index'] as int? ?? 255).compareTo(
            right['index'] as int? ?? 255,
          ),
        ),
    };
  }

  static String _macAddress(Iterable<int> bytes) => bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join(':')
      .toUpperCase();

  Future<bool> requestHostDisconnect() => service._runRfcomm(() async {
    if (!_connected) return false;
    // The earbuds report the address of this RFCOMM peer in tag 4.
    final fields = await _readFields([0x2B, 0x35, 3, 0]);
    final host = fields[4];
    if (!_connected ||
        host == null ||
        host.length != 6 ||
        host.every((byte) => byte == 0) ||
        host.every((byte) => byte == 0xFF)) {
      return false;
    }
    // The control socket can close before the earbuds send the reply.
    final reply = await _send([0x2B, 0x33, 2, 6, ...host], 0x2B, 0x33);
    return reply == null ||
        _statusCode(reply) == AndroidHeadphoneService._commandSucceeded ||
        _byte(AndroidHeadphoneService._tlv(reply)[31]) == 0;
  });

  Future<Map<String, dynamic>> _changeBondedDevice(
    Map<String, Object> arguments,
  ) async {
    final mac = arguments['mac'] as String;
    final action = arguments['action'];
    final devices =
        (await _bondedFreeBudsDevices())['devices']
            as List<Map<String, dynamic>>;
    final device = devices.where((entry) => entry['addr'] == mac).firstOrNull;
    if (device == null) {
      throw StateError('Device is no longer paired with the earbuds');
    }
    final bytes = mac.split(':').map((part) => int.parse(part, radix: 16));
    if (action == 'primary') {
      final response = await _send([0x2B, 0x32, 1, 6, ...bytes], 0x2B, 0x32);
      _requireNoRejection(response);
      final updated = await _bondedFreeBudsDevices();
      if (response != null &&
              _statusCode(response) ==
                  AndroidHeadphoneService._commandSucceeded ||
          (updated['devices'] as List<Map<String, dynamic>>).any(
            (entry) => entry['addr'] == mac && entry['primary'] == 1,
          )) {
        return updated;
      }
      _unconfirmed();
    }
    final code = switch (action) {
      'connect' => 1,
      'disconnect' => 2,
      'unpair' => 3,
      'reconnect' when device.containsKey('back_conn_permit') =>
        arguments['enabled'] == true ? 4 : 5,
      'audio-switch' when device.containsKey('allow_audio_auto_switch') =>
        arguments['enabled'] == true ? 6 : 7,
      _ => throw StateError('This device option is unavailable'),
    };
    final response = await _send([0x2B, 0x33, code, 6, ...bytes], 0x2B, 0x33);
    if (response == null) _unconfirmed();
    final fields = AndroidHeadphoneService._tlv(response);
    final status = _statusCode(response);
    final result = _byte(fields[31]);
    final operation = _byte(fields[30]);
    if (status != AndroidHeadphoneService._commandSucceeded &&
        !(result == 0 && (operation == null || operation == code))) {
      _unconfirmed();
    }
    return _bondedFreeBudsDevices();
  }

  Future<Map<String, dynamic>> _runFreeBudsFit() async {
    final mac = service._connectedMac;
    if (mac == null) throw StateError('FreeBuds disconnected');
    final wearing = await _send([0x2B, 0x25, 1, 0, 2, 0], 0x2B, 0x25);
    final fields = wearing == null
        ? null
        : AndroidHeadphoneService._tlv(wearing);
    if (_byte(fields?[1]) != 1 || _byte(fields?[2]) != 1) {
      throw StateError('Wear both earbuds for the fit test');
    }
    final version = await _send([0x2B, 0x37, 1, 0], 0x2B, 0x37);
    final steps =
        version != null && _byte(AndroidHeadphoneService._tlv(version)[1]) == 1
        ? 15
        : 8;
    final results = <String, String>{};
    final reports = Completer<void>();
    var interference = false;
    service._frameObserver = (key, data) {
      if (key != 0x2B27 || reports.isCompleted) return;
      final code = _byte(AndroidHeadphoneService._tlv(data)[1]);
      if (code == 4 || code == 5) {
        interference = true;
        reports.complete();
      } else if (code != null && code <= 3) {
        results[code < 2 ? 'left' : 'right'] = code.isEven ? 'good' : 'adjust';
        if (results.length == 2) reports.complete();
      }
    };
    try {
      final ack = await _send([0x2B, 0x26, 1, 0], 0x2B, 0x26);
      if (ack == null ||
          _byte(AndroidHeadphoneService._tlv(ack)[2]) != 0 ||
          !_connected) {
        throw StateError('Fit test start was not confirmed');
      }
      final complete = AndroidHeadphoneService._methodChannel
          .invokeMethod<void>('playFitAudio', {
            'mac': mac,
            'volume': steps / 15,
          });
      await Future.any<void>([
        Future.wait<void>([
          complete,
          reports.future,
        ], eagerError: true).then((_) {}),
        reports.future.then((_) {
          if (interference) throw StateError('Acoustic interference');
          return complete;
        }),
      ]).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw StateError('Incomplete fit report'),
      );
      if (interference) throw StateError('Acoustic interference');
      return results;
    } finally {
      service._frameObserver = null;
      try {
        await AndroidHeadphoneService._methodChannel.invokeMethod<void>(
          'stopFitAudio',
        );
      } finally {
        if (_connected) {
          await _send([0x2B, 0x26, 3, 0], 0x2B, 0x26);
        }
      }
    }
  }
}
