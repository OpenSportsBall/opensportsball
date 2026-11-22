// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/** Where people reach the maintainers: the Support and Privacy pages, and
 *  the app stores' support and privacy listings. */
export const SUPPORT_EMAIL = 'support@opensportsball.com';

export const REPO_URL = 'https://github.com/OpenSportsBall/opensportsball';

/** The iPhone app (App Store id 6827012317, also in app.html's Smart App Banner). */
export const APP_STORE_URL = 'https://apps.apple.com/app/id6827012317';

/** The Android app on Google Play. */
export const PLAY_STORE_URL = 'https://play.google.com/store/apps/details?id=dev.opensportsball.opensportsball';

/** The Mac app: the newest release's DMG. GitHub serves release files with no
 *  bandwidth limit; desktop/tool/release_mac.sh names the file the same in
 *  every release, so this link always gets the newest one. */
export const MAC_DOWNLOAD_URL = `${REPO_URL}/releases/latest/download/OpenSportsBall.dmg`;
