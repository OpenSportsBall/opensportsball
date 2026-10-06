// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../upload/account.dart';
import 'common.dart';

/// Link this phone to a website account by scanning the link QR code (or
/// typing the code, once the phone knows the API from an earlier link),
/// and show / forget the current link.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.account});
  final AccountManager account;
  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _relinking = false;

  AccountManager get a => widget.account;

  Future<void> _unlink() async {
    if (await confirm(
        context,
        'Unlink this phone?',
        'This phone forgets its account and stops uploading. Recordings stay on the phone. '
            'To remove it from the account too, delete it on the website.',
        'Unlink')) {
      await a.unlink();
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
          body: showForm
              ? _LinkForm(
                  account: a,
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
                  ],
                ),
        );
      },
    );
  }
}

class _LinkForm extends StatefulWidget {
  const _LinkForm({required this.account, required this.onLinked, this.message});
  final AccountManager account;
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

  @override
  void dispose() {
    _scanner.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _link(LinkRequest r) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.account.linkWith(r);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Linked. Recordings will upload.')));
      widget.onLinked();
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
        setState(() => _error = 'That is not a SportsBallVideo link code. '
            'Scan the code under "Link a phone" on the website.');
        continue;
      }
      _link(r);
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
              Text('Link to account', style: Theme.of(context).textTheme.titleMedium),
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
              const SizedBox(height: 12),
              ErrorText(_error),
            ],
          ),
        ),
      ],
    );
  }
}
