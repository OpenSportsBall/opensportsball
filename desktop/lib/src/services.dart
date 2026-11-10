// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The Mac's side of things: settings, the Keychain, where the engine and
/// the games' folders are, and the pre-flight checks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:osb_core/osb_core.dart';
import 'package:path_provider/path_provider.dart';

/// The signed-in session, in the login Keychain.
class KeychainTokenStore implements TokenStore {
  static const _key = 'osb.session';
  // The file-based login Keychain: works for an app signed without a
  // provisioning profile (the data-protection Keychain needs one).
  final _storage = const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// What people can change, kept in Application Support/settings.json.
class Settings extends ChangeNotifier {
  Settings._(this.file, this._values);

  final File file;
  final Map<String, Object?> _values;

  static Future<Settings> load() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/settings.json');
    Map<String, Object?> v = {};
    try {
      v = (jsonDecode(await f.readAsString()) as Map).cast();
    } on Object {
      // first launch
    }
    return Settings._(f, v);
  }

  /// For tests.
  @visibleForTesting
  factory Settings.inMemory(File file, [Map<String, Object?>? values]) => Settings._(file, values ?? {});

  String get siteUrl => _values['siteUrl'] as String? ?? defaultSiteUrl;

  /// Where each game's footage and results go (~100 GB a game).
  String get workFolder =>
      _values['workFolder'] as String? ??
      Platform.environment['OSB_WORK_FOLDER'] ??
      '${Platform.environment['HOME'] ?? '/tmp'}/Movies/OpenSportsBall';

  /// The engine's launcher. Unset: the one inside the app, or $OSB_ENGINE.
  String? get enginePath => _values['enginePath'] as String?;

  int get outputHeight => (_values['outputHeight'] as num?)?.toInt() ?? 1080;

  /// For development: process only this many chunks of a game (the job's
  /// maxChunks); null for the whole game.
  int? get maxChunks =>
      (_values['maxChunks'] as num?)?.toInt() ?? int.tryParse(Platform.environment['OSB_MAX_CHUNKS'] ?? '');

  Future<void> set(String key, Object? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(_values));
    notifyListeners();
  }

  /// The engine to run, or null when there is none.
  String? findEngine() {
    final candidates = [
      enginePath,
      // Inside the app bundle: OpenSportsBall.app/Contents/Resources/osb-engine/osb-engine
      '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/osb-engine/osb-engine',
      Platform.environment['OSB_ENGINE'],
    ];
    for (final c in candidates) {
      if (c != null && c.isNotEmpty && File(c).existsSync()) return c;
    }
    return null;
  }
}

/// One finding of the pre-flight checks.
class Check {
  const Check(this.ok, this.title, this.detail, {this.blocking = false});
  final bool ok;
  final String title;
  final String detail;

  /// Processing can't start until it's fixed.
  final bool blocking;
}

Future<String> _sh(String exe, List<String> args) async {
  try {
    final r = await Process.run(exe, args);
    return (r.stdout as String).trim();
  } on Object {
    return '';
  }
}

/// Free bytes on the volume holding [path] (or its nearest existing parent).
Future<int?> freeBytes(String path) async {
  var dir = Directory(path);
  while (!dir.existsSync() && dir.parent.path != dir.path) {
    dir = dir.parent;
  }
  final out = await _sh('/bin/df', ['-k', dir.path]);
  final lines = out.split('\n');
  if (lines.length < 2) return null;
  final cols = lines.last.split(RegExp(r'\s+'));
  final kb = cols.length > 3 ? int.tryParse(cols[3]) : null;
  return kb == null ? null : kb * 1024;
}

/// Whether the Mac runs on its power adapter (null: can't tell).
Future<bool?> onMains() async {
  final out = await _sh('/usr/bin/pmset', ['-g', 'batt']);
  if (out.contains("'AC Power'")) return true;
  if (out.contains("'Battery Power'")) return false;
  return null;
}

const gb = 1000 * 1000 * 1000;

/// docs/MAC-APP-PLAN.md, "Pre-flight": Apple Silicon, 16 GB, room for the
/// footage and the output, on mains power.
Future<List<Check>> preflight({required String workFolder, required int footageBytes, required int haveBytes}) async {
  final arm = await _sh('/usr/sbin/sysctl', ['-n', 'hw.optional.arm64']);
  final mem = int.tryParse(await _sh('/usr/sbin/sysctl', ['-n', 'hw.memsize'])) ?? 0;
  final free = await freeBytes(workFolder);
  final mains = await onMains();
  // The rest of the footage, then the engine's output and working files
  // (run checks its own share precisely before it starts).
  final need = (footageBytes - haveBytes).clamp(0, footageBytes) + 30 * gb;
  return [
    Check(
      arm == '1',
      'Apple Silicon',
      arm == '1' ? 'This Mac has an Apple chip.' : 'Processing needs a Mac with an Apple chip (M1 or newer).',
      blocking: arm != '1',
    ),
    Check(
      mem >= 16 * 1024 * 1024 * 1024,
      'Memory',
      mem >= 16 * 1024 * 1024 * 1024
          ? '${(mem / (1 << 30)).round()} GB'
          : '${(mem / (1 << 30)).round()} GB: 16 GB is recommended; processing may be slow or fail.',
    ),
    Check(
      free != null && free >= need,
      'Disk space',
      free == null
          ? "Couldn't check the free space."
          : '${(free / gb).toStringAsFixed(0)} GB free; this game needs about ${(need / gb).toStringAsFixed(0)} GB.',
      blocking: free != null && free < need,
    ),
    Check(
      mains != false,
      'Power',
      mains == false ? 'On battery: plug in. Processing pauses on battery.' : 'On the power adapter.',
    ),
  ];
}

/// Shows [path] in the Finder.
Future<void> revealInFinder(String path) => Process.run('/usr/bin/open', ['-R', path]);

/// Opens [path] with its default app.
Future<void> openFile(String path) => Process.run('/usr/bin/open', [path]);
