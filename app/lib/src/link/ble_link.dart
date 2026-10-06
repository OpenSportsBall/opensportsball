// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// BLE implementation of [PeerLink].
///
/// Main is the GATT peripheral: it advertises a service whose UUID is the
/// game id (shown in the pairing QR code). Secondary is the central: it
/// scans for that service, connects, and subscribes. Two characteristics
/// carry framed messages: `toSecondary` (notify) and `toMain` (write with
/// response).
library;

import 'dart:async';
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../protocol/framing.dart';
import '../protocol/messages.dart';
import 'peer_link.dart';

final kToSecondaryUuid = UUID.fromString('5b0e0001-7a2c-4f3e-9d61-2c8a5e4b9f10');
final kToMainUuid = UUID.fromString('5b0e0002-7a2c-4f3e-9d61-2c8a5e4b9f10');

/// Shared plumbing: state, framing, inbound decoding, serialized sends.
abstract class _BleLinkBase implements PeerLink {
  final _state = ValueNotifier(LinkState.idle);
  final _problem = ValueNotifier<String?>(null);
  final _messages = StreamController<Msg>.broadcast();
  final _encoder = FrameEncoder();
  final _decoder = FrameDecoder();
  final _subs = <StreamSubscription<Object?>>[];
  Future<void> _sendChain = Future.value();
  bool _disposed = false;

  @override
  ValueListenable<LinkState> get state => _state;

  @override
  ValueListenable<String?> get problem => _problem;

  @override
  Stream<Msg> get messages => _messages.stream;

  void _onFrame(Uint8List frame) {
    final payload = _decoder.add(frame);
    if (payload == null) return;
    try {
      _messages.add(Msg.decode(payload));
    } on Object catch (e) {
      debugPrint('ble: dropping undecodable message: $e');
    }
  }

  /// Waits until the adapter is on, asking for permission first.
  Future<bool> _ready(BluetoothLowEnergyManager manager) async {
    if (!await manager.authorize()) {
      _problem.value = 'Bluetooth permission was denied.';
      return false;
    }
    if (manager.state == BluetoothLowEnergyState.poweredOn) return true;
    _problem.value = 'Turn on Bluetooth.';
    await manager.stateChanged
        .firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn);
    _problem.value = null;
    return !_disposed;
  }

  @override
  Future<bool> send(Msg msg) {
    final done = Completer<bool>();
    _sendChain = _sendChain.then((_) async {
      try {
        done.complete(await _sendNow(msg.encode()));
      } on Object catch (e) {
        debugPrint('ble: send ${msg.type} failed: $e');
        done.complete(false);
      }
    });
    return done.future;
  }

  Future<bool> _sendNow(Uint8List payload);

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    await _messages.close();
  }
}

class MainBleLink extends _BleLinkBase {
  MainBleLink({required String gameId, PeripheralManager? manager})
      : _serviceUuid = UUID.fromString(gameId),
        _manager = manager ?? PeripheralManager();

  final UUID _serviceUuid;
  final PeripheralManager _manager;
  Central? _central;

  late final _toSecondary = GATTCharacteristic.mutable(
    uuid: kToSecondaryUuid,
    properties: [GATTCharacteristicProperty.notify],
    permissions: [],
    descriptors: [],
  );
  late final _toMain = GATTCharacteristic.mutable(
    uuid: kToMainUuid,
    properties: [GATTCharacteristicProperty.write],
    permissions: [GATTCharacteristicPermission.write],
    descriptors: [],
  );

  @override
  Future<void> start() async {
    if (!await _ready(_manager)) return;
    _subs
      ..add(_manager.characteristicWriteRequested.listen((e) async {
        if (e.characteristic.uuid != kToMainUuid) {
          await _manager.respondWriteRequestWithError(e.request,
              error: GATTError.requestNotSupported);
          return;
        }
        await _manager.respondWriteRequest(e.request);
        _onFrame(e.request.value);
      }))
      ..add(_manager.characteristicNotifyStateChanged.listen((e) async {
        if (e.characteristic.uuid != kToSecondaryUuid) return;
        if (e.state) {
          _central = e.central;
          _state.value = LinkState.connected;
          await _manager.stopAdvertising();
        } else if (_central?.uuid == e.central.uuid) {
          await _lost();
        }
      }))
      ..add(_manager.connectionStateChanged.listen((e) async {
        if (e.state == ConnectionState.disconnected &&
            _central?.uuid == e.central.uuid) {
          await _lost();
        }
      }));

    _subs.add(_manager.stateChanged.listen((e) async {
      if (e.state == BluetoothLowEnergyState.poweredOn) {
        _problem.value = null;
        _central = null;
        await _serve();
      } else {
        _central = null;
        _state.value = LinkState.idle;
        _problem.value = 'Turn on Bluetooth.';
      }
    }));
    await _serve();
  }

  /// (Re)publishes the GATT service and advertises. Android drops the GATT
  /// server when Bluetooth turns off, so this runs again when it comes back.
  Future<void> _serve() async {
    if (_disposed) return;
    try {
      await _manager.removeAllServices();
      await _manager.addService(GATTService(
        uuid: _serviceUuid,
        isPrimary: true,
        includedServices: [],
        characteristics: [_toSecondary, _toMain],
      ));
      await _advertise();
    } on Object catch (e) {
      _problem.value = 'Bluetooth error: $e';
    }
  }

  Future<void> _advertise() async {
    if (_disposed || _manager.state != BluetoothLowEnergyState.poweredOn) return;
    // No name: a 128-bit service UUID plus a name overflows Android's
    // 31-byte advertising packet.
    await _manager.startAdvertising(Advertisement(serviceUUIDs: [_serviceUuid]));
    _state.value = LinkState.advertising;
  }

  Future<void> _lost() async {
    _central = null;
    if (_disposed) return;
    await _advertise();
  }

  @override
  Future<bool> _sendNow(Uint8List payload) async {
    final central = _central;
    if (central == null) return false;
    final max = await _manager.getMaximumNotifyLength(central);
    for (final frame in _encoder.encode(payload, max)) {
      await _manager.notifyCharacteristic(central, _toSecondary, value: frame);
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    try {
      await _manager.stopAdvertising();
      await _manager.removeAllServices();
    } on Object catch (e) {
      debugPrint('ble: main cleanup: $e');
    }
  }
}

class SecondaryBleLink extends _BleLinkBase {
  SecondaryBleLink({required String gameId, CentralManager? manager})
      : _serviceUuid = UUID.fromString(gameId),
        _manager = manager ?? CentralManager();

  final UUID _serviceUuid;
  final CentralManager _manager;
  Peripheral? _peripheral;
  GATTCharacteristic? _toMain;
  bool _connecting = false;

  @override
  Future<void> start() async {
    if (!await _ready(_manager)) return;
    _subs
      ..add(_manager.discovered.listen((e) {
        if (_connecting || _peripheral != null) return;
        if (!e.advertisement.serviceUUIDs.contains(_serviceUuid)) return;
        unawaited(_connect(e.peripheral));
      }))
      ..add(_manager.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected &&
            _peripheral?.uuid == e.peripheral.uuid) {
          _peripheral = null;
          _toMain = null;
          unawaited(_search());
        }
      }))
      ..add(_manager.characteristicNotified.listen((e) {
        if (e.characteristic.uuid == kToSecondaryUuid) _onFrame(e.value);
      }))
      ..add(_manager.stateChanged.listen((e) {
        if (e.state == BluetoothLowEnergyState.poweredOn) {
          _problem.value = null;
          if (_peripheral == null && !_connecting) unawaited(_search());
        } else {
          _peripheral = null;
          _toMain = null;
          _state.value = LinkState.idle;
          _problem.value = 'Turn on Bluetooth.';
        }
      }));
    await _search();
  }

  Future<void> _search() async {
    if (_disposed || _manager.state != BluetoothLowEnergyState.poweredOn) return;
    _state.value = LinkState.searching;
    try {
      await _manager.startDiscovery(serviceUUIDs: [_serviceUuid]);
    } on Object catch (e) {
      _problem.value = 'Bluetooth error: $e';
    }
  }

  Future<void> _connect(Peripheral p) async {
    _connecting = true;
    _state.value = LinkState.connecting;
    try {
      await _manager.stopDiscovery();
      await _manager.connect(p);
      if (Platform.isAndroid) {
        // iOS negotiates MTU itself; Android starts at 23 bytes.
        await _manager.requestMTU(p, mtu: 247);
      }
      final services = await _manager.discoverGATT(p);
      final service = services.firstWhere((s) => s.uuid == _serviceUuid);
      GATTCharacteristic find(UUID u) =>
          service.characteristics.firstWhere((c) => c.uuid == u);
      final toSecondary = find(kToSecondaryUuid);
      _toMain = find(kToMainUuid);
      await _manager.setCharacteristicNotifyState(p, toSecondary, state: true);
      _peripheral = p;
      _state.value = LinkState.connected;
    } on Object catch (e) {
      debugPrint('ble: connect failed: $e');
      try {
        await _manager.disconnect(p);
      } on Object catch (_) {}
      _peripheral = null;
      await Future<void>.delayed(const Duration(seconds: 1));
      await _search();
    } finally {
      _connecting = false;
    }
  }

  @override
  Future<bool> _sendNow(Uint8List payload) async {
    final p = _peripheral, c = _toMain;
    if (p == null || c == null) return false;
    final max = await _manager.getMaximumWriteLength(p,
        type: GATTCharacteristicWriteType.withResponse);
    for (final frame in _encoder.encode(payload, max)) {
      await _manager.writeCharacteristic(p, c,
          value: frame, type: GATTCharacteristicWriteType.withResponse);
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    await super.dispose();
    try {
      await _manager.stopDiscovery();
      final p = _peripheral;
      if (p != null) await _manager.disconnect(p);
    } on Object catch (e) {
      debugPrint('ble: secondary cleanup: $e');
    }
  }
}
