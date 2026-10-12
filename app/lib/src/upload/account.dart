// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// Linking this phone to a website account (docs/API.md, "Linking a
/// phone"). The device token is kept in the platform keystore / keychain.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

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
  const LinkException(this.message);
  final String message;
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

/// The phone's link to an account. [revoked] turns on when the API says the
/// token no longer works (the device was unlinked on the website).
class AccountManager extends ChangeNotifier {
  AccountManager({required this.store, required this.secrets, required this.client});

  static const _key = 'account_link';

  final AppStore store;
  final SecretStore secrets;
  final http.Client client;

  AccountLink? _link;
  bool _revoked = false;
  bool _loaded = false;

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
      throw const LinkException('The server did not answer. Check the internet connection.');
    } on SocketException {
      throw const LinkException('Could not reach the server. Check the internet connection.');
    } on http.ClientException {
      throw const LinkException('Could not reach the server. Check the internet connection.');
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

  /// POST /devices/link-codes: a single-use code for this phone's account,
  /// which Main hands to its Secondary. Throws [LinkException].
  Future<LinkRequest> createLinkCode() async {
    final link = _link;
    if (link == null || _revoked) throw const LinkException('This phone is not linked to an account.');
    final http.Response res;
    try {
      res = await client.post(
        apiUri(link.apiUrl, '/devices/link-codes'),
        headers: {'Authorization': 'Bearer ${link.deviceToken}'},
      ).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const LinkException('The server did not answer. Check the internet connection.');
    } on SocketException {
      throw const LinkException('Could not reach the server. Check the internet connection.');
    } on http.ClientException {
      throw const LinkException('Could not reach the server. Check the internet connection.');
    }
    if (res.statusCode == 401) {
      markRevoked();
      throw const LinkException('This phone was unlinked on the website. Link it again.');
    }
    if (res.statusCode != 201) {
      throw LinkException('Could not get a link code (${res.statusCode}${serverMessage(res)}).');
    }
    final code = _decodeCode(res.body);
    if (code == null) throw const LinkException('The server sent an unexpected answer.');
    return LinkRequest(apiUrl: link.apiUrl, code: code);
  }

  static String? _decodeCode(String body) {
    try {
      final c = (jsonDecode(body) as Map)['code'];
      return c is String ? normalizeLinkCode(c) : null;
    } on Object {
      return null;
    }
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
