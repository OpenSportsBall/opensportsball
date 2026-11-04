// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../upload/account.dart';
import '../upload/sign_in.dart';
import 'common.dart';

/// Link this phone to a website account by signing in (or creating an
/// account), by scanning the link QR code, or by typing the code once the
/// phone knows the API from an earlier link; and show / forget the current
/// link, or go to the website to delete the account.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.account, this.signIn, this.openUrl});
  final AccountManager account;

  /// For tests; the browser sheet otherwise.
  final AppSignIn? signIn;

  /// For tests; the phone's browser otherwise.
  final Future<bool> Function(Uri url)? openUrl;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _relinking = false;

  AccountManager get a => widget.account;

  Future<void> _unlink() async {
    if (!await confirm(
        context,
        'Unlink this phone?',
        'This phone leaves its account and stops uploading the recordings it made as Main. '
            'Recordings stay on the phone, and it can then join another account.',
        'Unlink')) {
      return;
    }
    try {
      await a.unlink();
    } on LinkException catch (e) {
      if (!mounted) return;
      if (await confirm(
          context,
          'Forget the account anyway?',
          '${e.message}\n\nThe account keeps this phone until you remove it on the website\'s '
              'Devices page; until then it cannot join another account.',
          'Forget anyway')) {
        await a.unlink(force: true);
      }
    }
  }

  /// Deleting the account takes signing in again, so it happens on the
  /// website's Account page (docs/API.md, `DELETE /me`). The app keeps
  /// only a device token, which can't delete an account. Phones linked to
  /// another deployment by QR code still go to [defaultSiteUrl]: the app
  /// doesn't know that deployment's website.
  Future<void> _deleteAccount() async {
    final url = Uri.parse('$defaultSiteUrl/account');
    if (!await confirm(
        context,
        'Delete your account?',
        'You will sign in on ${url.host} and confirm there. Deleting the account removes all its '
            'games and footage, unlinks its phones, and deletes the sign-in, for good. '
            'Recordings on this phone stay until you delete them here.',
        'Continue')) {
      return;
    }
    final open = widget.openUrl ?? (u) => launchUrl(u, mode: LaunchMode.externalApplication);
    final opened = await open(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open a browser. Go to $url to delete your account.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: a,
      builder: (context, _) {
        final link = a.link;
        final showForm = link == null || a.revoked || _relinking;
        return Scaffold(
          appBar: AppBar(title: const Text('Account')),
          body: SafeArea(child: showForm
              ? _LinkForm(
                  account: a,
                  signIn: widget.signIn ?? AppSignIn(client: a.client),
                  message: a.revoked ? 'This phone was unlinked; link it again.' : null,
                  onLinked: () => setState(() => _relinking = false),
                )
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Row(children: [
                      Icon(Icons.cloud_done_outlined, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 12),
                      Text('This phone is linked to an account.',
                          style: Theme.of(context).textTheme.titleMedium),
                    ]),
                    const SizedBox(height: 12),
                    if (link.email != null) InfoRow('Email', link.email!),
                    InfoRow('Server', Uri.parse(link.apiUrl).host),
                    InfoRow('Account', link.accountId),
                    const SizedBox(height: 24),
                    OverflowBar(
                      spacing: 12,
                      alignment: MainAxisAlignment.end,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _unlink,
                          icon: const Icon(Icons.link_off),
                          label: const Text('Unlink this phone'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => setState(() => _relinking = true),
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Link again'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _deleteAccount,
                        style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('Delete account…'),
                      ),
                    ),
                  ],
                )),
        );
      },
    );
  }
}

class _LinkForm extends StatefulWidget {
  const _LinkForm({required this.account, required this.signIn, required this.onLinked, this.message});
  final AccountManager account;
  final AppSignIn signIn;
  final VoidCallback onLinked;
  final String? message;
  @override
  State<_LinkForm> createState() => _LinkFormState();
}

class _LinkFormState extends State<_LinkForm> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _lastScanned;
  String _site = defaultSiteUrl;

  @override
  void dispose() {
    _scanner.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _link(LinkRequest r) => _run(() => widget.account.linkWith(r));

  /// A scanned code names its own server, and everything this phone records
  /// will upload there. So a code for any server but this phone's own, or
  /// the website's in the Server setting, is confirmed first: a stranger's
  /// QR code must not quietly send a family's footage elsewhere.
  Future<void> _linkScanned(LinkRequest r) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final trusted = await _isOwnServer(r.apiUrl);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!trusted && !await _confirmServer(r.apiUrl)) return;
    await _link(r);
  }

  Future<bool> _isOwnServer(String apiUrl) async {
    final known = widget.account.knownApiUrl;
    if (known != null && sameApiUrl(known, apiUrl)) return true;
    try {
      return sameApiUrl((await widget.signIn.loadConfig(_site)).apiUrl, apiUrl);
    } on LinkException {
      return false; // can't tell (offline?): ask
    }
  }

  Future<bool> _confirmServer(String apiUrl) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('A different server'),
        content: Text('This code links the phone to a server at ${Uri.parse(apiUrl).host}, '
            'not to ${Uri.parse(_site).host}. Everything this phone records will upload there.\n\n'
            'Only continue if you trust whoever runs that server.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Link anyway')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _signIn({required bool signUp}) =>
      _run(() => widget.signIn.signInAndLink(widget.account, siteUrl: _site, signUp: signUp));

  Future<void> _run(Future<AccountLink> Function() linking) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await linking();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Linked. Recordings will upload.')));
      widget.onLinked();
    } on SignInCanceled {
      // Closed the sign-in sheet: nothing to say.
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeSite() async {
    final field = TextEditingController(text: _site);
    final typed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server'),
        content: TextField(
          controller: field,
          autofocus: true,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            helperText: 'The website address of your OpenSportsBall server.',
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(defaultSiteUrl), child: const Text('Default')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(field.text), child: const Text('Use')),
        ],
      ),
    );
    field.dispose();
    if (typed == null || !mounted) return;
    final site = normalizeSiteUrl(typed);
    setState(() {
      if (site == null) {
        _error = 'Type the website address, like opensportsball.com.';
      } else {
        _site = site;
        _error = null;
      }
    });
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      // A code that just failed stays in view; don't retry it in a loop.
      if (raw == null || raw == _lastScanned) continue;
      _lastScanned = raw;
      final r = parseLinkUri(raw);
      if (r == null) {
        setState(() => _error = 'That is not a OpenSportsBall link code. '
            'Scan the code under "Link a phone" on the website.');
        continue;
      }
      _linkScanned(r);
      return;
    }
  }

  void _submitCode() {
    final api = widget.account.knownApiUrl;
    final code = normalizeLinkCode(_code.text);
    if (api == null) return;
    if (code == null) {
      setState(() => _error = 'Codes are 8 letters and digits, like ABCD-EFGH.');
      return;
    }
    _link(LinkRequest(apiUrl: api, code: code));
  }

  @override
  Widget build(BuildContext context) {
    final knownApi = widget.account.knownApiUrl;
    return Row(
      children: [
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(controller: _scanner, onDetect: _onDetect),
                if (_busy) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ),
        SizedBox(
          width: 320,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.message != null) ErrorText(widget.message),
              Text('Sign in', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('Sign in to your account, or create one, to link this phone.'),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : () => _signIn(signUp: false),
                child: const Text('Sign in'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : () => _signIn(signUp: true),
                child: const Text('Create account'),
              ),
              Row(children: [
                Expanded(
                  child: Text('Server: ${Uri.parse(_site).host}',
                      style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                ),
                TextButton(onPressed: _busy ? null : _changeSite, child: const Text('Change')),
              ]),
              ErrorText(_error),
              const SizedBox(height: 16),
              Text('Or scan a link code', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('On the website, sign in and choose "Link a phone". '
                  'Point this phone at the QR code shown there.'),
              const SizedBox(height: 16),
              if (knownApi != null) ...[
                Text('Or type the code', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: 'ABCD-EFGH',
                    helperText: 'Server: ${Uri.parse(knownApi).host}',
                  ),
                  onSubmitted: (_) => _submitCode(),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _busy ? null : _submitCode,
                  child: const Text('Link'),
                ),
              ] else
                Text('Typing the code works after this phone has been linked once.',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}
