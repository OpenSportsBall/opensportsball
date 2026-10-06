// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

// Client-only single-page app: config.json and the signed-in user are only
// known in the browser, so nothing is server-rendered or prerendered.
export const ssr = false;
export const prerender = false;
