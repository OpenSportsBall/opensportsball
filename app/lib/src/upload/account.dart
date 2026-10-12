// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Linking this phone to a website account (docs/API.md, "Linking a
/// phone"), and recording grants: Main creates them, Secondary keeps the
/// ones Main sends. Tokens are kept in the platform keystore / keychain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../model.dart';
import '../storage/store.dart';

/// What linking returned. Stored as one JSON value in [SecretStore].
class AccountLink {
  const AccountLink({required this.apiUrl, required this.deviceToken, required this.accountId});

  factory AccountLink.fromJson(Map<String, Object?> j) => AccountLink(
        apiUrl: j['apiUrl'] as String,
        deviceToken: j['deviceToken'] as String,
        accountId: j['accountId'] as String,
      );

  final String apiUrl;
  final String deviceToken;
  final String accountId;

  Map<String, Object?> toJson() =>
      {'apiUrl': apiUrl, 'deviceToken': deviceToken, 'accountId': accountId};
}

/// Builds `<apiUrl><path>`; [apiUrl] may end in a slash or a stage path.
Uri apiUri(String apiUrl, String path) =>
    Uri.parse('${apiUrl.replaceAll(RegExp(r'/+$'), '')}$path');

const _codeAlphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// `ABCD-EFGH`, `abcdefgh` or `ABCD EFGH` → `ABCDEFGH`; null if it can't be
/// a link code.
String? normalizeLinkCode(String typed) {
  final code = typed.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  if (code.length != 8) return null;
  for (final c in code.split('')) {
    if (!_codeAlphabet.contains(c)) return null;
  }
  return code;
}

/// Only HTTPS APIs are accepted: the phone sends its token there.
bool isAcceptableApiUrl(String url) {
  final u = Uri.tryParse(url);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty;
}

class LinkRequest {
  const LinkRequest({required this.apiUrl, required this.code});
  final String apiUrl;
  final String code;
}

/// Parses `opensportsball://link?v=1&api=<url>&code=<code>`.
LinkRequest? parseLinkUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'opensportsball' || uri.host != 'link') return null;
  if (uri.queryParameters['v'] != '1') return null;
  final api = uri.queryParameters['api'];
  final code = normalizeLinkCode(uri.queryParameters['code'] ?? '');
  if (api == null || code == null || !isAcceptableApiUrl(api)) return null;
  return LinkRequest(apiUrl: api, code: code);
}

class LinkException implements Exception {
  const LinkException(this.message, {this.offline = false});
  final String message;

  /// The server could not be reached; trying again later may work.
  final bool offline;
  @override
  String toString() => message;
}

/// Small key/value secret store, so tests can use memory.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  SecureSecretStore()
      : _storage = const FlutterSecureStorage(
          // Readable after first unlock, so a later background uploader
          // can use it while the screen is locked.
          iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
        );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

const _unreachable =
    LinkException('Could not reach the server. Check the internet connection.', offline: true);
const _noAnswer = LinkException('The server did not answer. Check the internet connection.', offline: true);

/// The phone's link to an account. [revoked] turns on when the API says the
/// token no longer works (the device was unlinked on the website).
///
/// Also keeps the recording grants other Main phones gave this phone, one
/// per game ([grantFor]). They do not depend on this phone's own link.
class AccountManager extends ChangeNotifier {
  AccountManager({required this.store, required this.secrets, required this.client});

  static const _key = 'account_link';

  final AppStore store;
  final SecretStore secrets;
  final http.Client client;

  AccountLink? _link;
  bool _revoked = false;
  bool _loaded = false;
  final _grants = <String, RecordingGrant?>{};

  static String _grantKey(String gameId) => 'grant_$gameId';

  AccountLink? get link => _link;
  bool get linked => _link != null;
  bool get loaded => _loaded;

  /// The server rejected the token (401). Linking again clears it.
  bool get revoked => _revoked;

  /// API of the latest link, for typing a code instead of scanning.
  String? get knownApiUrl => _link?.apiUrl ?? store.uploadSettings.lastApiUrl;

  Future<void> load() async {
    try {
      final raw = await secrets.read(_key);
      if (raw != null) _link = AccountLink.fromJson((jsonDecode(raw) as Map).cast());
    } on Object catch (e) {
      debugPrint('could not read account link: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// POST /devices/link. Throws [LinkException] with a message for people.
  Future<AccountLink> linkWith(LinkRequest r) async {
    if (!isAcceptableApiUrl(r.apiUrl)) {
      throw const LinkException('That link code points to an address that is not HTTPS.');
    }
    final id = store.identity;
    final http.Response res;
    try {
      res = await client
          .post(
            apiUri(r.apiUrl, '/devices/link'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'code': r.code,
              'deviceId': id.deviceId,
              'platform': id.platform,
              'model': id.model,
            }),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw _noAnswer;
    } on SocketException {
      throw _unreachable;
    } on http.ClientException {
      throw _unreachable;
    }
    switch (res.statusCode) {
      case 200:
        break;
      case 404:
        throw const LinkException('That code was not found. Check it, or make a new one on the website.');
      case 410:
        throw const LinkException('That code has expired or was already used. Make a new one on the website.');
      case 409:
        throw const LinkException(
            'This phone is linked to a different account. Unlink it there on the website first.');
      default:
        throw LinkException('Linking failed (${res.statusCode}${serverMessage(res)}).');
    }
    final Map<String, Object?> body;
    try {
      body = (jsonDecode(res.body) as Map).cast();
    } on Object {
      throw const LinkException('The server sent an unexpected answer.');
    }
    final token = body['deviceToken'], account = body['accountId'];
    if (token is! String || account is! String) {
      throw const LinkException('The server sent an unexpected answer.');
    }
    final link = AccountLink(apiUrl: r.apiUrl, deviceToken: token, accountId: account);
    await secrets.write(_key, jsonEncode(link.toJson()));
    await store.saveUploadSettings(store.uploadSettings.copyWith(lastApiUrl: r.apiUrl));
    _link = link;
    _revoked = false;
    notifyListeners();
    return link;
  }

  /// POST /games/{gameId}/grants: lets the phone [deviceId] upload its
  /// own part of [gameId] into this phone's account. Main sends the result
  /// to its Secondary. Throws [LinkException] ([LinkException.offline] if
  /// the server could not be reached).
  Future<RecordingGrant> createGrant({required String gameId, required String deviceId}) async {
    final link = _link;
    if (link == null || _revoked) throw const LinkException('This phone is not linked to an account.');
    final http.Response res;
    try {
      res = await client
          .post(
            apiUri(link.apiUrl, '/games/${Uri.encodeComponent(gameId)}/grants'),
            headers: {'Authorization': 'Bearer ${link.deviceToken}', 'Content-Type': 'application/json'},
            body: jsonEncode({'deviceId': deviceId}),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw _noAnswer;
    } on SocketException {
      throw _unreachable;
    } on http.ClientException {
      throw _unreachable;
    }
    if (res.statusCode == 401) {
      markRevoked();
      throw const LinkException('This phone was unlinked on the website. Link it again.');
    }
    if (res.statusCode >= 500 || res.statusCode == 429) {
      throw LinkException('The server had a problem (${res.statusCode}${serverMessage(res)}).', offline: true);
    }
    if (res.statusCode != 201) {
      throw LinkException('Could not get upload permission (${res.statusCode}${serverMessage(res)}).');
    }
    try {
      final b = (jsonDecode(res.body) as Map).cast<String, Object?>();
      return RecordingGrant(
        // The address this phone uses, which keeps any stage path that the
        // server's own `apiUrl` would leave out.
        apiUrl: link.apiUrl,
        token: b['grantToken'] as String,
        accountId: b['accountId'] as String,
        gameId: b['gameId'] as String,
        expiresAt: DateTime.parse(b['expiresAt'] as String),
      );
    } on Object {
      throw const LinkException('The server sent an unexpected answer.');
    }
  }

  /// The grant another Main phone gave this phone for [gameId], if any.
  Future<RecordingGrant?> grantFor(String gameId) async {
    if (_grants.containsKey(gameId)) return _grants[gameId];
    RecordingGrant? g;
    try {
      final raw = await secrets.read(_grantKey(gameId));
      if (raw != null) g = RecordingGrant.fromJson((jsonDecode(raw) as Map).cast());
    } on Object catch (e) {
      debugPrint('could not read grant for $gameId: $e');
    }
    return _grants[gameId] = g;
  }

  /// Keeps a grant from Main; replaces any earlier one for its game.
  Future<void> saveGrant(RecordingGrant g) async {
    await secrets.write(_grantKey(g.gameId), jsonEncode(g.toJson()));
    _grants[g.gameId] = g;
    notifyListeners();
  }

  /// The server refused the grant for [gameId] (expired or replaced). A new
  /// one from Main replaces it.
  Future<void> markGrantRejected(String gameId) async {
    final g = await grantFor(gameId);
    if (g == null || g.rejected) return;
    await saveGrant(g.asRejected());
  }

  /// Forgets the token on this phone. The website still lists the device
  /// until it is removed there.
  Future<void> unlink() async {
    await secrets.delete(_key);
    _link = null;
    _revoked = false;
    notifyListeners();
  }

  void markRevoked() {
    if (_revoked) return;
    _revoked = true;
    notifyListeners();
  }
}

/// `": <message>"` from an API error body, or empty.
String serverMessage(http.Response res) {
  try {
    final m = (jsonDecode(res.body) as Map)['message'];
    return m is String && m.isNotEmpty ? ': $m' : '';
  } on Object {
    return '';
  }
}
