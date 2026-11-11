# web

The OpenSportsBall account website. Parents sign in, link their phones by
QR code, and follow each game's uploads. It is a static single-page app
(SvelteKit + `@sveltejs/adapter-static`, Svelte 5, TypeScript) served from
S3 + CloudFront, and talks to the API described in
[`docs/API.md`](../docs/API.md). License: Apache-2.0.

## Pages

| Path | What |
|---|---|
| `/` | What OpenSportsBall is, plus **Sign in** (Cognito managed login also handles sign up). Signed-in users go to `/games`. |
| `/callback` | Finishes the Cognito sign-in redirect. |
| `/games` | Games, newest first, with recording count and status. |
| `/game?id=<gameId>` | Recordings with per-phone upload progress, and for each ready recording its processing: **Process in the cloud** (accounts an admin has switched it on for), progress, Cancel, the link to the checks, then the video to watch and download. Refreshes every 15 s while anything is uploading, every 4 s while a machine is working. |
| `/check?game=…&recording=…&job=…` | The two checks a cloud job waits for: the pitch (approve the drawn lines, or drag the named points and have it redrawn) and the kit groups (tap who doesn't belong; say whether groups should be merged or one split). Draws what the engine wrote; see `docs/API.md`, "Processing jobs". |
| `/devices` | Linked phones, Unlink, and **Link a phone** (QR code, `ABCD-EFGH` code, expiry countdown; polls every 3 s until the phone shows up). |
| `/admin` | Admins only (Cognito `admins` group; the nav link shows for them): totals, then every account with status, phones, games, recordings and storage, sortable and filterable; a row expands to the account id, phones, the **Cloud processing** switch, oldest footage, and the account's games and recordings with their size, each with a two-step **Delete** (also for footage left with no record). See `api/README.md` to add an admin. |

Not built yet (later phases): connect YouTube, default upload settings
(privacy, title template). Default video privacy will be
unlisted or private: the footage shows minors.

The game page takes the id as a query parameter, not a path segment, so
every route is a fixed file path and static hosting works.

## Quick start (no AWS needed)

```sh
npm install
npm run dev:mock      # http://localhost:5173
```

`dev:mock` runs `vite dev --mode mock`. In that mode the dev server answers
`/config.json` with [`config.mock.json`](config.mock.json), which sets
`"apiUrl": "mock"`. The site then:

- skips Cognito and uses a fake signed-in user (`parent@example.com`), who
  is an admin, so `/admin` shows sample accounts.
  **Sign out** shows the signed-out home page; **Sign in** signs back in.
- answers every API call from an in-memory mock
  ([`src/lib/mock.ts`](src/lib/mock.ts)) behind the real API client: three
  games with recordings in every status, two linked phones. Upload progress
  moves forward every 15 s. After **Link a phone**, a "Samsung Galaxy S24"
  links itself about 5 seconds later. The oldest game has a processed
  recording and one to process: a job there takes about 15 seconds to
  reach the checks (a drawn pitch whose first fit is off, and kit groups
  with one to split), a few seconds per redo, and 30 seconds to "make" a
  test-pattern video.

Mock data lives in memory, so a full page reload starts over. Any
`config.json` with `"apiUrl": "mock"` turns mock mode on, including a built
copy.

## Configuration: `/config.json`

Nothing deployment-specific is compiled in. On startup the site fetches
`/config.json`:

```json
{
  "apiUrl": "https://abc123.execute-api.us-east-1.amazonaws.com",
  "region": "us-east-1",
  "userPoolId": "us-east-1_XXXX",
  "userPoolClientId": "xxxxxxxx",
  "cognitoDomain": "https://opensportsball-xxxx.auth.us-east-1.amazoncognito.com"
}
```

- **Deployed:** the infrastructure writes `config.json` next to
  `index.html` in the bucket.
- **Local, against a real backend:** copy
  `static/config.example.json` to `static/config.json` (gitignored), fill it
  in, and run `npm run dev`.

The Cognito app client needs:

- callback URL `<site origin>/callback`
- sign-out URL `<site origin>/`
- authorization code grant, scopes `openid` and `email`, no client secret

Sign-in uses authorization code + PKCE (`oidc-client-ts`), and the session
is kept in `localStorage`. There is no silent renew: when the access token
expires, or the API returns 401, the user is sent through managed login
again and comes back to the same page. Sign out clears the local session
and goes to Cognito's `/logout`, which returns to `/`.

## Build and deploy output

```sh
npm run build         # writes build/
```

`build/` holds `index.html` (the SPA shell, used for every route), `_app/`
(hashed, immutable assets) and the contents of `static/`. Upload it to the
site bucket. CloudFront must answer missing paths (S3 403/404) with
`/index.html` and status 200 so `/games`, `/devices` and `/callback` load.
`_app/immutable/*` can be cached forever; `index.html` and `config.json`
should not be cached.

## Scripts

| Command | What |
|---|---|
| `npm run dev:mock` | Dev server with the mock API, no AWS |
| `npm run dev` | Dev server using `static/config.json` |
| `npm run build` | Production build into `build/` |
| `npm run preview` | Serve the production build locally |
| `npm run check` | `svelte-check` type checking |
| `npm test` | Unit tests (vitest): API client, formatting, config, mock API, and a processing job from the button to the video |

## Layout

```
src/
  app.html, app.css           page shell, colour tokens (light + dark)
  lib/
    api.ts                    typed API client (token, 401, errors)
    auth.ts                   Cognito (oidc-client-ts) and mock sign-in
    config.ts                 loads and checks /config.json
    format.ts                 bytes, dates, codes, labels
    mock.ts                   in-memory mock of the API
    mockScene.ts, mockVideo.ts  the made-up game and video the mock's jobs show
    poll.ts                   non-overlapping polling helper
    session.svelte.ts         app-wide state (config, auth, API client)
    types.ts                  API shapes from docs/API.md
    components/               StatusBadge, ProgressBar, ErrorBanner,
                              JobPanel, PitchCheck, KitsCheck
  routes/                     /, /callback, /games, /game, /check, /devices
tests/                        vitest suites
```

SvelteKit 3 has no `$lib` alias; `src/lib` is imported as `#lib/...`
through `"imports"` in `package.json`.

## Licensing

<!-- REUSE-IgnoreStart -->
Every source file starts with an SPDX header
(`SPDX-License-Identifier: Apache-2.0`; an HTML comment in `.svelte`
files). Dependencies must not be GPL or AGPL; see
[`docs/LICENSING.md`](../docs/LICENSING.md). Runtime dependencies:
`oidc-client-ts` (Apache-2.0) and `qrcode` (MIT).

<!-- REUSE-IgnoreEnd -->
