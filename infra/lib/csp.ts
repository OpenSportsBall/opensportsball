// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * The website's Content-Security-Policy header, sent by CloudFront.
 *
 * Scripts are restricted by the page itself: SvelteKit writes a <meta>
 * policy with the hash of the start-up script it inlines
 * (web/vite.config.ts), so the hash always ships with the page it matches.
 * A browser enforces both policies, so `script-src` here only has to let
 * that through; everything else is decided here, where the API and sign-in
 * addresses are known.
 */
export function siteContentSecurityPolicy(o: { loginUrl: string; region: string }): string {
  const directives: [string, string[]][] = [
    ['default-src', ["'self'"]],
    // The page's own <meta> policy narrows this to its files and one hash.
    ['script-src', ["'self'", "'unsafe-inline'"]],
    // config.json, the API, and the sign-in token endpoint. The API is any
    // HTTP API in the region: naming this stack's own would make a
    // dependency cycle (the API's CORS names the distribution).
    [
      'connect-src',
      [
        "'self'",
        `https://*.execute-api.${o.region}.amazonaws.com`,
        o.loginUrl,
        `https://cognito-idp.${o.region}.amazonaws.com`,
      ],
    ],
    ['img-src', ["'self'", 'data:']],
    ['font-src', ["'self'"]],
    // Svelte sets style attributes.
    ['style-src', ["'self'", "'unsafe-inline'"]],
    ['object-src', ["'none'"]],
    ['base-uri', ["'self'"]],
    ['form-action', ["'self'"]],
    // No other site may show these pages in a frame (clickjacking the
    // account and delete buttons).
    ['frame-ancestors', ["'none'"]],
  ];
  return directives.map(([name, values]) => `${name} ${values.join(' ')}`).join('; ');
}
