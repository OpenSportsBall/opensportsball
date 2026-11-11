// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// The `osb` command's signed-in session, in a file only its owner can
/// read (as the AWS and GitHub command lines keep theirs). The Mac app
/// keeps its own in the Keychain; the two sign in separately.
library;

import 'dart:io';

import 'api.dart';

/// `$OSB_SESSION_FILE`, else Application Support/OpenSportsBall on a Mac
/// and ~/.config/opensportsball elsewhere.
String defaultSessionFile([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
  return env['OSB_SESSION_FILE'] ??
      (Platform.isMacOS
          ? '$home/Library/Application Support/OpenSportsBall/cli-session.json'
          : '$home/.config/opensportsball/cli-session.json');
}

class FileTokenStore implements TokenStore {
  FileTokenStore(this.path);
  final String path;

  @override
  Future<String?> read() async {
    try {
      return await File(path).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(String value) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    // Made empty and closed to others first, then filled and moved into
    // place, so the tokens are never in a file others can read.
    final tmp = File('$path.tmp');
    await tmp.writeAsString('');
    if (!Platform.isWindows) await Process.run('chmod', ['600', tmp.path]);
    await tmp.writeAsString(value, flush: true);
    await tmp.rename(path);
  }

  @override
  Future<void> delete() async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // already gone
    }
  }
}
