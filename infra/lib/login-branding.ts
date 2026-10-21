// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Managed login (Cognito's sign-in, sign-up and reset pages) styled like the
 * website. Colors are the site's tokens from web/src/app.css; keep the two in
 * step. Managed login can't load custom fonts, so text stays in its default
 * typeface.
 *
 * The settings shape is Cognito's branding document; anything left out keeps
 * Cognito's default. To try changes, edit the style in the console's
 * branding editor and copy the result back with
 * `aws cognito-idp describe-managed-login-branding-by-client`.
 */

interface Palette {
  bg: string;
  surface: string;
  surface2: string;
  border: string;
  borderStrong: string;
  text: string;
  textMuted: string;
  accent: string;
  accentStrong: string;
  accentText: string;
  focus: string;
  danger: string;
  dangerBg: string;
  ok: string;
  okBg: string;
  warn: string;
  warnBg: string;
  track: string;
}

const light: Palette = {
  bg: '#fbf6ee',
  surface: '#ffffff',
  surface2: '#f3ebde',
  border: '#e2d6c3',
  borderStrong: '#8f7e6a',
  text: '#2b2119',
  textMuted: '#6e5f4f',
  accent: '#2a7a46',
  accentStrong: '#1f6237',
  accentText: '#ffffff',
  focus: '#2a6aa8',
  danger: '#b33b27',
  dangerBg: '#fbe6e1',
  ok: '#2a7a46',
  okBg: '#e2f1e3',
  warn: '#8a5800',
  warnBg: '#fdf0d2',
  track: '#e9dfcf',
};

const dark: Palette = {
  bg: '#18140f',
  surface: '#221d17',
  surface2: '#2c261e',
  border: '#3d352b',
  borderStrong: '#7d6e5c',
  text: '#f5eee3',
  textMuted: '#b9ab98',
  accent: '#5cc27f',
  accentStrong: '#7fd59c',
  accentText: '#0e2416',
  focus: '#8cbcef',
  danger: '#ff8f7a',
  dangerBg: '#3d1d17',
  ok: '#5cc27f',
  okBg: '#1b3324',
  warn: '#f6c45c',
  warnBg: '#3a2e14',
  track: '#352e25',
};

const RADIUS = 14; // --radius
const RADIUS_SM = 8; // --radius-sm

/** Cognito wants RRGGBBAA without the '#'. */
function hex(palette: Palette): Record<keyof Palette, string> {
  return Object.fromEntries(Object.entries(palette).map(([k, v]) => [k, `${v.slice(1)}ff`])) as Record<keyof Palette, string>;
}

/** The same component settings for each color mode. */
function modes<T>(f: (c: Record<keyof Palette, string>) => T): { lightMode: T; darkMode: T } {
  return { lightMode: f(hex(light)), darkMode: f(hex(dark)) };
}

export function loginBrandingSettings() {
  return {
    categories: {
      global: {
        colorSchemeMode: 'DYNAMIC',
        pageHeader: { enabled: false },
        pageFooter: { enabled: false },
        spacingDensity: 'REGULAR',
      },
      form: {
        displayGraphics: true,
        location: { horizontal: 'CENTER', vertical: 'CENTER' },
      },
    },
    components: {
      pageBackground: { image: { enabled: false }, ...modes((c) => ({ color: c.bg })) },
      form: {
        borderRadius: RADIUS,
        backgroundImage: { enabled: false },
        logo: { enabled: true, location: 'CENTER', position: 'TOP', formInclusion: 'IN' },
        ...modes((c) => ({ backgroundColor: c.surface, borderColor: c.border })),
      },
      pageText: modes((c) => ({ headingColor: c.text, bodyColor: c.text, descriptionColor: c.textMuted })),
      primaryButton: modes((c) => ({
        defaults: { backgroundColor: c.accent, textColor: c.accentText },
        hover: { backgroundColor: c.accentStrong, textColor: c.accentText },
        active: { backgroundColor: c.accentStrong, textColor: c.accentText },
        disabled: { backgroundColor: c.track, borderColor: c.track },
      })),
      secondaryButton: modes((c) => ({
        defaults: { backgroundColor: c.surface, borderColor: c.borderStrong, textColor: c.text },
        hover: { backgroundColor: c.surface2, borderColor: c.borderStrong, textColor: c.text },
        active: { backgroundColor: c.track, borderColor: c.borderStrong, textColor: c.text },
      })),
      alert: {
        borderRadius: RADIUS_SM,
        ...modes((c) => ({ error: { backgroundColor: c.dangerBg, borderColor: c.danger } })),
      },
      favicon: { enabledTypes: ['SVG'] },
    },
    componentClasses: {
      buttons: { borderRadius: RADIUS },
      input: {
        borderRadius: RADIUS_SM,
        ...modes((c) => ({
          defaults: { backgroundColor: c.surface, borderColor: c.borderStrong },
          placeholderColor: c.textMuted,
        })),
      },
      inputLabel: modes((c) => ({ textColor: c.text })),
      inputDescription: modes((c) => ({ textColor: c.textMuted })),
      link: modes((c) => ({ defaults: { textColor: c.accent }, hover: { textColor: c.accentStrong } })),
      focusState: modes((c) => ({ borderColor: c.focus })),
      divider: modes((c) => ({ borderColor: c.border })),
      optionControls: modes((c) => ({
        defaults: { backgroundColor: c.surface, borderColor: c.borderStrong },
        selected: { backgroundColor: c.accent, foregroundColor: c.accentText },
      })),
      dropDown: {
        borderRadius: RADIUS_SM,
        ...modes((c) => ({
          defaults: { itemBackgroundColor: c.surface },
          hover: { itemBackgroundColor: c.surface2, itemBorderColor: c.borderStrong, itemTextColor: c.text },
          match: { itemBackgroundColor: c.surface2, itemTextColor: c.accent },
        })),
      },
      statusIndicator: modes((c) => ({
        success: { backgroundColor: c.okBg, borderColor: c.ok, indicatorColor: c.ok },
        warning: { backgroundColor: c.warnBg, borderColor: c.warn, indicatorColor: c.warn },
        error: { backgroundColor: c.dangerBg, borderColor: c.danger, indicatorColor: c.danger },
      })),
    },
  };
}

/**
 * The site's mark (web/static/favicon.svg) as the form logo and favicon.
 * Cognito's SVG sanitizer rejects ARIA attributes and foreign namespaces,
 * so this is a plain copy.
 */
const LOGO_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">' +
  '<path d="M30.50 4.04A28 28 0 0 0 30.50 59.96Z" fill="#2a7a46"/>' +
  '<path d="M33.50 4.04A28 28 0 0 1 33.50 59.96Z" fill="#2a7a46"/>' +
  '<path d="M25.50 21.50L43.50 32.00L25.50 42.50Z" fill="#f4b63a" stroke="#f4b63a" stroke-width="4.00" stroke-linejoin="round"/>' +
  '</svg>';

export function loginBrandingAssets() {
  const bytes = Buffer.from(LOGO_SVG).toString('base64');
  return ['FORM_LOGO', 'FAVICON_SVG'].flatMap((category) =>
    ['LIGHT', 'DARK'].map((colorMode) => ({ category, colorMode, extension: 'SVG', bytes })),
  );
}
