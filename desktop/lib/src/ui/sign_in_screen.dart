// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:osb_core/osb_core.dart';

import '../auth.dart';
import '../brand.dart';
import '../services.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth, required this.settings});
  final AuthController auth;
  final Settings settings;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late final _site = TextEditingController(text: widget.settings.siteUrl);
  bool _showSite = false;

  Future<void> _go({bool signUp = false}) async {
    await widget.settings.set('siteUrl', _site.text.trim() == defaultSiteUrl ? null : _site.text.trim());
    await widget.auth.signInAt(_site.text, signUp: signUp);
  }

  @override
  Widget build(BuildContext context) {
    final c = BrandColors.of(context);
    final t = Theme.of(context).textTheme;
    final auth = widget.auth;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: ListenableBuilder(
            listenable: auth,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('OpenSportsBall', style: t.headlineMedium, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                Text(
                  'Turn a game your phones recorded into one video that follows the play, on this Mac, for free. '
                  'Sign in with the same account as your phones.',
                  style: t.bodyLarge?.copyWith(color: c.inkMuted),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: auth.busy ? null : _go,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: auth.busy
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Sign in'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: auth.busy ? null : () => _go(signUp: true),
                  child: const Text('Create an account'),
                ),
                if (auth.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    auth.error!,
                    style: t.bodyMedium?.copyWith(color: c.coral),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 24),
                if (!_showSite)
                  TextButton(
                    onPressed: () => setState(() => _showSite = true),
                    child: Text('Another OpenSportsBall server?', style: t.bodySmall?.copyWith(color: c.inkMuted)),
                  )
                else
                  TextField(
                    controller: _site,
                    decoration: const InputDecoration(labelText: 'Website', helperText: 'Where your account is'),
                    onSubmitted: (_) => _go(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
