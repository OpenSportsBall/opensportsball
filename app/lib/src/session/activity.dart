// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

/// What the camera side of the app is doing right now, so other parts
/// (the upload queue) can stay out of its way without knowing about the
/// controllers. [LocalRecorder] reports into [DeviceActivity.instance].
class DeviceActivity extends ChangeNotifier {
  DeviceActivity();

  static final instance = DeviceActivity();

  final _recording = <Object>{};
  final _cameraOpen = <Object>{};

  /// A recording is in progress on this phone.
  bool get recording => _recording.isNotEmpty;

  /// A camera session screen holds the camera (and the keep-awake flag).
  bool get cameraOpen => _cameraOpen.isNotEmpty;

  void setRecording(Object owner, bool on) => _set(_recording, owner, on);
  void setCameraOpen(Object owner, bool on) => _set(_cameraOpen, owner, on);

  void _set(Set<Object> set, Object owner, bool on) {
    final changed = on ? set.add(owner) : set.remove(owner);
    if (changed) notifyListeners();
  }
}
