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
  const AccountLink(
      {required this.apiUrl, required this.deviceToken, required this.accountId, this.email});

  factory AccountLink.fromJson(Map<String, Object?> j) => AccountLink(
        apiUrl: j['apiUrl'] as String,
        deviceToken: j['deviceToken'] as String,
        accountId: j['accountId'] as String,
        email: j['email'] as String?,
      );

  final String apiUrl;
  final String deviceToken;
  final String accountId;

  /// The account's email when the phone linked. Null for links made before
  /// the server sent it.
  final String? email;

  Map<String, Object?> toJson() => {
        'apiUrl': apiUrl,
        'deviceToken': deviceToken,
        'accountId': accountId,
        if (email != null) 'email': email,
      };
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

final _grantToken = RegExp(r'^osbg_[A-Za-z0-9_-]{43}$');

/// Parses an upload permission link from the website (docs/API.md),
/// `opensportsball://grant?v=1&api=<url>&account=<id>&game=<id>&ticket=<osbg_...>&exp=<time>`,
/// into a grant ticket for that game, not yet bound to this phone.
RecordingGrant? parseGrantUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme != 'opensportsball' || uri.host != 'grant') return null;
  final q = uri.queryParameters;
  if (q['v'] != '1') return null;
  final api = q['api'], account = q['account'], game = q['game'], ticket = q['ticket'];
  final expiresAt = DateTime.tryParse(q['exp'] ?? '');
  if (api == null || !isAcceptableApiUrl(api) || account == null || account.isEmpty) return null;
  if (game == null || game.isEmpty || ticket == null || !_grantToken.hasMatch(ticket) || expiresAt == null) {
    return null;
  }
  return RecordingGrant(
      apiUrl: api, token: ticket, accountId: account, gameId: game, expiresAt: expiresAt, unredeemed: true);
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

  static const _ticketsKey = 'grant_tickets';
  static const _pendingKey = 'grant_redemptions';

  /// How many grant tickets Main keeps for pairings without signal.
  static const ticketStock = 3;

  /// Unbound grant tickets for this phone's account ([GrantTicket]).
  final _tickets = <GrantTicket>[];

  /// Tickets handed to a Secondary that the server has not bound yet.
  final _pending = <PendingRedemption>[];

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
      _tickets.addAll(await _readList(_ticketsKey, GrantTicket.fromJson));
      _pending.addAll(await _readList(_pendingKey, PendingRedemption.fromJson));
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
    final email = body['email'];
    final link = AccountLink(
        apiUrl: r.apiUrl,
        deviceToken: token,
        accountId: account,
        email: email is String ? email : null);
    await secrets.write(_key, jsonEncode(link.toJson()));
    await store.saveUploadSettings(store.uploadSettings.copyWith(lastApiUrl: r.apiUrl));
    if (_tickets.any((x) => x.accountId != link.accountId)) {
      _tickets.clear();
      await _saveTickets();
    }
    _link = link;
    _revoked = false;
    notifyListeners();
    // Linking happens online: stock tickets now, in case this phone records
    // as Main somewhere without signal before it is online again.
    unawaited(refillTickets());
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

  // --- Grant tickets: pairing without signal ------------------------------

  /// Usable tickets in stock, for the screens.
  int get ticketsInStock => _tickets.where((x) => x.usableAt(DateTime.now())).length;

  /// Tickets handed over that still have to be redeemed, for the screens.
  int get pendingRedemptions => _pending.length;

  /// While online: tops the stock up to [ticketStock] tickets
  /// (POST /grant-tickets). Quietly does nothing offline or unlinked.
  Future<void> refillTickets() async {
    final link = _link;
    if (link == null || _revoked) return;
    final now = DateTime.now();
    final before = _tickets.length;
    _tickets.removeWhere((x) => !x.usableAt(now) || x.accountId != link.accountId);
    final missing = ticketStock - _tickets.length;
    if (missing <= 0) {
      if (_tickets.length != before) await _saveTickets();
      return;
    }
    try {
      final b = await _post(link.apiUrl, '/grant-tickets', {'count': missing},
          token: link.deviceToken, expect: 201);
      for (final raw in b['tickets'] as List) {
        final m = (raw as Map).cast<String, Object?>();
        _tickets.add(GrantTicket(
          ticket: m['ticket'] as String,
          accountId: link.accountId,
          expiresAt: DateTime.parse(m['expiresAt'] as String),
        ));
      }
    } on LinkException catch (e) {
      debugPrint('could not refill grant tickets: $e');
    } on Object catch (e) {
      debugPrint('unexpected grant ticket answer: $e');
    }
    await _saveTickets();
    notifyListeners();
  }

  /// For Main without signal: a grant for [deviceId] on [gameId] made from
  /// a ticket in stock, or null if there is none. The ticket is spent, and
  /// remembered so this phone redeems it once online ([redeemPending]).
  Future<RecordingGrant?> grantFromTicket({required String gameId, required String deviceId}) async {
    final link = _link;
    if (link == null || _revoked) return null;
    final now = DateTime.now();
    final usable = _tickets.where((x) => x.usableAt(now) && x.accountId == link.accountId).toList()
      ..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
    if (usable.isEmpty) return null;
    final ticket = usable.first;
    _tickets.remove(ticket);
    _pending.add(PendingRedemption(apiUrl: link.apiUrl, ticket: ticket.ticket, gameId: gameId, deviceId: deviceId));
    await _saveTickets();
    await _savePending();
    notifyListeners();
    return RecordingGrant(
      apiUrl: link.apiUrl,
      token: ticket.ticket,
      accountId: link.accountId,
      gameId: gameId,
      // Redeeming starts the grant's 14 days; until then, the ticket's own.
      expiresAt: ticket.expiresAt,
      unredeemed: true,
    );
  }

  /// While online: binds every ticket this phone handed over to its game
  /// and Secondary (POST /grants/redeem), so Main's manifest, which names
  /// that phone, is accepted. A refused ticket is dropped: retrying won't
  /// help, and the upload screen shows the manifest's error.
  Future<void> redeemPending() async {
    for (final p in List.of(_pending)) {
      try {
        await _post(p.apiUrl, '/grants/redeem', {'ticket': p.ticket, 'gameId': p.gameId, 'deviceId': p.deviceId});
        _pending.remove(p);
      } on LinkException catch (e) {
        if (e.offline) return;
        debugPrint('grant ticket refused: $e');
        _pending.remove(p);
      }
      await _savePending();
      notifyListeners();
    }
  }

  /// For Secondary: binds Main's ticket [g] to this phone ([deviceId]) and
  /// keeps the result as an ordinary grant. Throws [LinkException].
  Future<RecordingGrant> redeemGrant(RecordingGrant g, {required String deviceId}) async {
    final b = await _post(g.apiUrl, '/grants/redeem', {'ticket': g.token, 'gameId': g.gameId, 'deviceId': deviceId});
    final DateTime expiresAt;
    try {
      expiresAt = DateTime.parse(b['expiresAt'] as String);
    } on Object {
      throw const LinkException('The server sent an unexpected answer.');
    }
    final redeemed = g.redeemed(expiresAt);
    await saveGrant(redeemed);
    return redeemed;
  }

  /// A ticket from an upload permission link ([parseGrantUri]): binds it
  /// to this phone now. Without internet it is kept unbound, and the upload
  /// queue binds it before its first upload; returns false then. Throws
  /// [LinkException] when the server refuses it.
  Future<bool> acceptGrantLink(RecordingGrant ticket, {required String deviceId}) async {
    try {
      await redeemGrant(ticket, deviceId: deviceId);
      return true;
    } on LinkException catch (e) {
      if (!e.offline) rethrow;
      await saveGrant(ticket);
      return false;
    }
  }

  /// POSTs JSON and returns the decoded answer. Throws [LinkException]
  /// ([LinkException.offline] when trying later may work).
  Future<Map<String, Object?>> _post(String apiUrl, String path, Map<String, Object?> body,
      {String? token, int expect = 200}) async {
    final http.Response res;
    try {
      res = await client
          .post(
            apiUri(apiUrl, path),
            headers: {
              if (token != null) 'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw _noAnswer;
    } on SocketException {
      throw _unreachable;
    } on http.ClientException {
      throw _unreachable;
    }
    if (res.statusCode == 401 && token != null) {
      markRevoked();
      throw const LinkException('This phone was unlinked on the website. Link it again.');
    }
    if (res.statusCode >= 500 || res.statusCode == 429) {
      throw LinkException('The server had a problem (${res.statusCode}${serverMessage(res)}).', offline: true);
    }
    if (res.statusCode != expect) {
      throw LinkException('The server refused (${res.statusCode}${serverMessage(res)}).');
    }
    try {
      return (jsonDecode(res.body) as Map).cast<String, Object?>();
    } on Object {
      throw const LinkException('The server sent an unexpected answer.');
    }
  }

  Future<List<T>> _readList<T>(String key, T Function(Map<String, Object?>) fromJson) async {
    final raw = await secrets.read(key);
    if (raw == null) return [];
    return [for (final e in jsonDecode(raw) as List) fromJson((e as Map).cast())];
  }

  Future<void> _saveTickets() => _saveList(_ticketsKey, [for (final x in _tickets) x.toJson()]);
  Future<void> _savePending() => _saveList(_pendingKey, [for (final x in _pending) x.toJson()]);

  Future<void> _saveList(String key, List<Map<String, Object?>> items) =>
      items.isEmpty ? secrets.delete(key) : secrets.write(key, jsonEncode(items));

  /// Removes this phone from its account (POST /devices/unlink), so it can
  /// join another one, then forgets the token. Throws [LinkException] if the
  /// server could not do it; with [force] the phone forgets the token anyway,
  /// and the account keeps it until it is removed on the website.
  Future<void> unlink({bool force = false}) async {
    final link = _link;
    if (link != null && !_revoked && !force) {
      final http.Response res;
      try {
        res = await client.post(
          apiUri(link.apiUrl, '/devices/unlink'),
          headers: {'Authorization': 'Bearer ${link.deviceToken}'},
        ).timeout(const Duration(seconds: 30));
      } on TimeoutException {
        throw _noAnswer;
      } on SocketException {
        throw _unreachable;
      } on http.ClientException {
        throw _unreachable;
      }
      // 401: already removed on the website.
      if (res.statusCode != 204 && res.statusCode != 401) {
        throw LinkException('Could not unlink (${res.statusCode}${serverMessage(res)}).',
            offline: res.statusCode >= 500 || res.statusCode == 429);
      }
    }
    await secrets.delete(_key);
    _link = null;
    _revoked = false;
    // Tickets belong to the account just left. Pending redemptions stay:
    // they don't need this phone's link, and the Secondary's footage
    // depends on them.
    _tickets.clear();
    await _saveTickets();
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

/// An unbound grant ticket in Main's stock (docs/API.md, `POST /grant-tickets`).
class GrantTicket {
  const GrantTicket({required this.ticket, required this.accountId, required this.expiresAt});

  factory GrantTicket.fromJson(Map<String, Object?> j) => GrantTicket(
        ticket: j['ticket'] as String,
        accountId: j['accountId'] as String,
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );

  final String ticket;
  final String accountId;
  final DateTime expiresAt;

  /// Leaves a day's margin, so a ticket handed over is still good when the
  /// first phone reaches the internet.
  bool usableAt(DateTime now) => now.isBefore(expiresAt.subtract(const Duration(days: 1)));

  Map<String, Object?> toJson() =>
      {'ticket': ticket, 'accountId': accountId, 'expiresAt': expiresAt.toUtc().toIso8601String()};
}

/// A ticket Main handed to [deviceId] for [gameId], to bind once online.
class PendingRedemption {
  const PendingRedemption({required this.apiUrl, required this.ticket, required this.gameId, required this.deviceId});

  factory PendingRedemption.fromJson(Map<String, Object?> j) => PendingRedemption(
        apiUrl: j['apiUrl'] as String,
        ticket: j['ticket'] as String,
        gameId: j['gameId'] as String,
        deviceId: j['deviceId'] as String,
      );

  final String apiUrl;
  final String ticket;
  final String gameId;
  final String deviceId;

  Map<String, Object?> toJson() => {'apiUrl': apiUrl, 'ticket': ticket, 'gameId': gameId, 'deviceId': deviceId};
}
