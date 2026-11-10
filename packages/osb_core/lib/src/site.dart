// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/// A deployment's website and what its `/config.json` says: where the API
/// and the sign-in pages are, and the apps' Cognito clients.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The website apps sign in to unless people type another. Builds for
/// another deployment pass `--dart-define=OSB_SITE=https://...`.
const defaultSiteUrl = String.fromEnvironment('OSB_SITE', defaultValue: 'https://opensportsball.com');

/// A request to the website, the API or Cognito that went wrong, worded for
/// people. [offline] when the server couldn't be reached at all.
class OsbException implements Exception {
  const OsbException(this.message, {this.offline = false, this.status});
  final String message;
  final bool offline;

  /// The HTTP status, when the server answered.
  final int? status;

  @override
  String toString() => message;
}

/// Only HTTPS servers are accepted: apps send tokens there.
bool isAcceptableApiUrl(String url) {
  final u = Uri.tryParse(url);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty;
}

/// Builds `<apiUrl><path>`; [apiUrl] may end in a slash or a stage path.
Uri apiUri(String apiUrl, String path) => Uri.parse('${apiUrl.replaceAll(RegExp(r'/+$'), '')}$path');

/// `https://example.com/`, `example.com` → `https://example.com`; null if
/// it can't be a website address.
String? normalizeSiteUrl(String typed) {
  var s = typed.trim().replaceAll(RegExp(r'/+$'), '');
  if (s.isEmpty) return null;
  if (!s.contains('://')) s = 'https://$s';
  return isAcceptableApiUrl(s) ? s : null;
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

/// The parts of a website's `/config.json` apps use.
class SiteConfig {
  const SiteConfig({
    required this.siteUrl,
    required this.apiUrl,
    required this.cognitoDomain,
    this.appClientId,
    this.desktopClientId,
  });

  final String siteUrl;
  final String apiUrl;
  final String cognitoDomain;

  /// The phone app's client (short-lived tokens: it keeps a device token).
  final String? appClientId;

  /// The desktop apps' client (a 30-day refresh token, like the website's).
  final String? desktopClientId;

  /// Parses `/config.json`. Throws [FormatException].
  factory SiteConfig.fromJson(String siteUrl, Map<String, Object?> j) {
    final api = j['apiUrl'], domain = j['cognitoDomain'];
    if (api is! String || !isAcceptableApiUrl(api) || domain is! String || !isAcceptableApiUrl(domain)) {
      throw const FormatException('not an OpenSportsBall config');
    }
    String? id(Object? v) => v is String && v.isNotEmpty ? v : null;
    return SiteConfig(
      siteUrl: siteUrl,
      apiUrl: api.replaceAll(RegExp(r'/+$'), ''),
      cognitoDomain: domain.replaceAll(RegExp(r'/+$'), ''),
      appClientId: id(j['appClientId']),
      desktopClientId: id(j['desktopClientId']),
    );
  }

  Map<String, Object?> toJson() => {
        'siteUrl': siteUrl,
        'apiUrl': apiUrl,
        'cognitoDomain': cognitoDomain,
        if (appClientId != null) 'appClientId': appClientId,
        if (desktopClientId != null) 'desktopClientId': desktopClientId,
      };
}

/// GET `<siteUrl>/config.json`. Throws [OsbException].
Future<SiteConfig> loadSiteConfig(http.Client client, String siteUrl) async {
  final res = await send(() => client.get(Uri.parse('$siteUrl/config.json')));
  if (res.statusCode != 200) {
    throw OsbException('$siteUrl is not an OpenSportsBall website (${res.statusCode}).', status: res.statusCode);
  }
  try {
    return SiteConfig.fromJson(siteUrl, (jsonDecode(res.body) as Map).cast());
  } on Object {
    throw OsbException('$siteUrl is not an OpenSportsBall website.');
  }
}

/// Runs [request] with a timeout, turning network failures into
/// [OsbException]s with `offline` set.
Future<http.Response> send(Future<http.Response> Function() request,
    {Duration timeout = const Duration(seconds: 30)}) async {
  try {
    return await request().timeout(timeout);
  } on TimeoutException {
    throw const OsbException('The server did not answer. Check the internet connection.', offline: true);
  } on SocketException {
    throw const OsbException('Could not reach the server. Check the internet connection.', offline: true);
  } on http.ClientException {
    throw const OsbException('Could not reach the server. Check the internet connection.', offline: true);
  }
}
