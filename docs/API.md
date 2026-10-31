# OpenSportsBall API (v1)

The contract between the phones, the website and the backend (`api/`,
`infra/`). Change all sides together.

## Basics

- Base URL: the API Gateway HTTP API URL, published to the website in
  `/config.json` (below) and to phones in the link QR code.
- JSON in and out, `Content-Type: application/json`.
- Errors: HTTP status plus `{"error": "<code>", "message": "<text>"}`.
  Codes used: `bad_request`, `unauthorized`, `forbidden`, `not_found`,
  `gone`, `conflict`, `invalid_manifest`, `internal`.
- Times are ISO-8601 UTC strings unless a field name ends in `Ms`.

## Who is calling

There are two kinds of caller, on separate routes.

**People, on the website.** Sign in with Cognito managed login
(authorization code + PKCE). Calls carry `Authorization: Bearer <Cognito
access token>`. The account id is the token's `sub`.

**Phones.** A phone is linked to an account once, by scanning a QR code
shown on the website, or by signing in (or signing up) in the app
("Signing in from the app" below). Linking returns a long-lived device token
(`osbd_` + 43 base64url characters). Calls carry
`Authorization: Bearer <device token>`. The server stores only a SHA-256
hash of the token. Unlinking the device, on the website or from the phone
(`POST /devices/unlink`), revokes it.

**Phones recording for someone else's game.** A Secondary uploads its part
of a game into Main's account with a recording grant (`osbg_` + 43
base64url characters) that Main gets from `POST /games/{gameId}/grants`
and sends over Bluetooth. The Secondary may be linked to another account,
or to none; that does not change. A grant reaches only `PUT .../report`,
`POST /uploads` and `POST /uploads/complete`, only for its game and only
as its device (`403 forbidden` otherwise), and expires after 14 days
(`401`). A phone can hold grants from several accounts at once. When Main
has no signal at the field, it gives the Secondary a **grant ticket**
fetched earlier instead (`POST /grant-tickets`), which either phone binds
to the game later (`POST /grants/redeem`). If the Secondary got no grant
at all (Main was not linked), the account owner makes a ticket for that
game on the website (`POST /games/{gameId}/grant-tickets`) and sends it to
the phone as a link ("Upload permission link" below).

## Website config

The deployed site serves `/config.json`:

```json
{
  "apiUrl": "https://abc123.execute-api.us-east-1.amazonaws.com",
  "region": "us-east-1",
  "userPoolId": "us-east-1_XXXX",
  "userPoolClientId": "xxxxxxxx",
  "appClientId": "yyyyyyyy",
  "cognitoDomain": "https://opensportsball-xxxx.auth.us-east-1.amazoncognito.com"
}
```

`appClientId` is the phone app's Cognito client ("Signing in from the
app"); the website ignores it.

## Linking a phone

Link QR code / URI (shown on the website):

```
opensportsball://link?v=1&api=<url-encoded apiUrl>&code=<code>
```

`code` is 8 characters from `ABCDEFGHJKMNPQRSTUVWXYZ23456789`, shown to
people as `ABCD-EFGH` (phones send it without the dash, uppercase). Valid
for 10 minutes, single use.

Only a phone that records as Main needs linking. A Secondary uploads with
a recording grant that Main creates (`POST /games/{gameId}/grants`) and
sends over Bluetooth (`app/lib/src/protocol/messages.dart`, `GrantMsg`),
whatever account the Secondary is linked to, if any.

## Signing in from the app

A phone can link itself without a QR code. The app knows a website
(`https://opensportsball.com` unless changed in the app), reads its
`/config.json`, and opens Cognito managed login in a browser sheet
(authorization code + PKCE, client `appClientId`, redirect
`opensportsball://auth`). The same pages let people create an account.
With the Cognito access token the app calls `POST /link-codes` for
itself, then `POST /devices/link` with that code, exactly as if it had
scanned it. It keeps only the device token; the Cognito tokens are
dropped.

## Upload permission link

The website's game page shows a link and its QR code for a phone that
recorded the game without a grant:

```
https://<site>/grant#<osbg_... ticket>
```

The ticket is in the fragment, so it never reaches the web server's logs.
That page needs no sign-in: it looks the ticket up (`POST /grants/lookup`)
and its button opens the app with
`opensportsball://grant?v=1&api=<url-encoded apiUrl>&account=<accountId>&game=<gameId>&ticket=<osbg_...>&exp=<expiresAt>`
(the lookup's `appUri`). The app checks it has a recording of that game,
then redeems the ticket (`POST /grants/redeem`) for itself. Links made
before 2026-10-29 carry those parameters in the fragment instead of only
the ticket; the page still accepts them.

## Routes for people (Cognito token)

### `GET /me`
→ `200 {"accountId": "...", "email": "..."}`

### `POST /link-codes`
→ `201 {"code": "ABCDEFGH", "expiresAt": "...", "linkUri": "opensportsball://link?..."}`

### `GET /devices`
→ `200 {"devices": [{"deviceId", "platform", "model", "linkedAt", "lastSeenAt"}]}`
(`lastSeenAt` may be null)

### `DELETE /devices/{deviceId}`
→ `204`. The device's token stops working immediately.

### `GET /games`
→ `200 {"games": [{"gameId", "createdAt", "recordedAt", "recordingCount", "status"}]}`,
newest first (by `recordedAt`, or `createdAt` while that is null). `status`
is the least-finished status of its recordings.

`createdAt` is when the server first heard of the game or recording;
`recordedAt` is when recording started: the earliest segment
`startedAtDeviceMs` in Main's manifest or a phone's report (for a game, its
earliest recording). It is null until one of those has arrived.

### `POST /games/{gameId}/grant-tickets`
A grant ticket for one game of the account, for a phone that recorded it
without a grant from Main.
→ `201 {"ticket": "osbg_...", "apiUrl", "accountId", "gameId", "expiresAt", "appUri": "opensportsball://grant?..."}`

- Like Main's tickets (`POST /grant-tickets`), it can call nothing until
  redeemed, but it can only be bound to this game (`409 conflict`
  otherwise), and lapses unredeemed after 7 days.
- `404 not_found`: no such game on the account.

### `GET /games/{gameId}`
→ `200`

```json
{
  "gameId": "...",
  "createdAt": "...",
  "recordedAt": "... | null",
  "recordings": [
    {
      "recordingId": "...",
      "createdAt": "...",
      "recordedAt": "... | null",
      "status": "waiting_for_manifest | uploading | ready",
      "hasManifest": true,
      "devices": [
        {
          "deviceId": "...", "role": "main | secondary | null", "model": "... | null",
          "expectedSegments": 18, "uploadedSegments": 12,
          "expectedBytes": 20000000000, "uploadedBytes": 13000000000
        }
      ]
    }
  ]
}
```

Before the manifest arrives, `devices` lists only phones that have
uploaded something, with `role`, `model`, `expectedSegments` and
`expectedBytes` null. After it arrives, a phone that has not reported its
segments yet has `expectedSegments` and `expectedBytes` null.

### `DELETE /games/{gameId}/recordings/{recordingId}`
Deletes one recording for good. → `204`

- Removes everything under
  `accounts/<accountId>/games/<gameId>/recordings/<recordingId>/` in the
  bucket (manifest, segments, any processing output), aborting multipart
  uploads still open there, and the recording's items: the recording and
  its manifest, each phone's report, uploaded-file and upload-in-progress
  records. The game and its other recordings stay.
- Phones are refused from then on (`410 gone`, below).
- Calling it again for a deleted recording is `204` (it finishes a delete
  that failed partway). `404 not_found`: no such recording on the account,
  including another account's.

### `DELETE /games/{gameId}`
Deletes a game and all its recordings for good. → `204`

- Removes everything under `accounts/<accountId>/games/<gameId>/`
  (aborting open multipart uploads), every recording's items as above, the
  game's grant records, and website tickets for it not yet redeemed.
- Grant tokens already on a Secondary are left to expire (14 days), so
  that phone is told the game was deleted (`410`) rather than that it was
  signed out (`401`).
- Again for a deleted game is `204`; `404 not_found` as above.

## Routes for phones

A recording or game deleted on the website stays deleted: the manifest,
report and upload routes answer `410 gone` ("This recording was deleted
on the website." / "This game was deleted on the website.") for it, and
never create it again. Phones should treat it as final and drop it from
their upload queue. A segment that still lands in the bucket (an upload
finishing as it was deleted) is deleted when its S3 event arrives.

### `POST /devices/link` (no token: the code is the credential)
Body: `{"code": "ABCDEFGH", "deviceId": "<uuid>", "platform": "ios|android", "model": "..."}`
→ `200 {"deviceToken": "osbd_...", "accountId": "..."}`
- `404 not_found`: no such code. `410 gone`: expired or already used.
- `409 conflict`: this deviceId is linked to a different account (unlink
  it there first).
- Re-linking a deviceId to the same account replaces its old token.

### `POST /devices/unlink`
Device token only. The phone leaves its account, so it can link to
another one; its recordings stay. → `204`. Same effect as
`DELETE /devices/{deviceId}` on the website.

The phones never need to be near each other to finish an upload. Main's
manifest lists both phones but only Main's segments; the Secondary sends
its own segment list (`PUT .../report`) from wherever it reaches Wi-Fi,
before or after the manifest arrives.

### `POST /games/{gameId}/grants`
Device token only (a grant cannot create grants). Lets the phone
`deviceId` upload its own report and segments for this game into the
caller's account.
Body: `{"deviceId": "<uuid>"}`
→ `201 {"grantToken": "osbg_...", "apiUrl": "https://...", "accountId", "gameId", "deviceId", "expiresAt"}`

- Asking again for the same game and phone replaces the grant; the old
  token stops working.
- `400 bad_request` for the caller's own deviceId.

### `POST /grant-tickets`
Device token only. For pairings without signal: Main keeps a few
**tickets**, grant tokens for its account that are not yet tied to a game
or phone, and hands one to its Secondary over Bluetooth when it can't
reach the server. Until redeemed, a ticket can call nothing (`401`).
Body: `{"count": 1-5}`
→ `201 {"tickets": [{"ticket": "osbg_...", "expiresAt"}], "apiUrl", "accountId", "open": n}`

- Tops up to `count` new tickets, keeping at most 5 unredeemed per Main
  phone (`open` counts them); fewer, or none, if the stock is full.
- An unredeemed ticket lapses after 90 days.

### `POST /grants/redeem`
No token: the ticket is the credential, as the code is for linking. Binds
a ticket to one game and phone; from then on the ticket is that phone's
grant for that game (14 days, as `POST /games/{gameId}/grants`).
Body: `{"ticket": "osbg_...", "gameId", "deviceId"}`
→ `200`, the same shape as `POST /games/{gameId}/grants`, with
`grantToken` equal to the ticket.

- Either phone redeems it, whichever reaches the internet first; Main
  before uploading its manifest (which names the Secondary), the Secondary
  before its first upload. The same binding again is a no-op.
- `409 conflict`: already bound to another game or phone, or a website
  ticket for another game.
  `404 not_found`: no such ticket. `410 gone`: lapsed unredeemed.
  `400 bad_request`: binding it to the phone that fetched it.

### `POST /grants/lookup`
No token: the ticket is the credential. For the website's /grant page.
Body: `{"ticket": "osbg_..."}`
→ `200`, the same shape as `POST /games/{gameId}/grant-tickets`, plus
`"used": true | false`.

- Only website tickets (`POST /games/{gameId}/grant-tickets`); Main's are
  `404 not_found`, as are unknown ones.
- `used`: a phone has redeemed it; `expiresAt` is then that grant's.
- `410 gone`: lapsed unredeemed.

### `PUT /games/{gameId}/recordings/{recordingId}/manifest`
Body: the manifest (`shared/schemas/manifest.schema.json`). Main must list
its own segments; it may leave out other devices' `segments`.
→ `200 {"status": "uploading | ready", "missing": [{"deviceId", "fileName"}], "awaitingReports": ["<deviceId>"]}`

- `awaitingReports`: devices whose segments are not known yet (neither
  the manifest nor a report lists them).
- Only the manifest's `main` device may upload it (`403 forbidden`).
- Every other device in it must be linked to the caller's account or
  hold a grant for this game (`403 forbidden`, message names the device).
- Path ids must equal `gameId` / `sessionId` (`400 bad_request`).
- Schema violations: `400 invalid_manifest` with `"details": [...]`.
- Re-uploading the same manifest is fine; a different one for a recording
  that is already `ready` is `409 conflict`.

### `PUT /games/{gameId}/recordings/{recordingId}/report`
Body: the caller's own device entry (the schema's `$defs/device`), with
its `segments`. → same response as the manifest.

- `deviceId` must be the caller (`403 forbidden`); segments must be named
  for it (`400 invalid_manifest`).
- A phone's report wins over whatever Main's manifest lists for it.
- A Secondary that Main's manifest leaves out (it had no grant at the
  field) counts once it reports, if the manifest has no other Secondary.
  If the recording was already `ready` with Main alone, its first report
  sets it back to `uploading`; it is `ready` again, with a second
  `RecordingReady`, once that phone's files are in.
- Re-sending the same report is fine; a different one once the recording
  is `ready` is `409 conflict`.

### `POST /uploads`
Starts or resumes uploading one segment file.
Body: `{"gameId", "recordingId", "fileName", "bytes", "sha256"}`

- `fileName` must be `<caller deviceId>_<3 digits>.mp4`; a phone uploads
  only its own files.
- `bytes`: 1 byte to 50 GiB.

→ `200`, either

```json
{"alreadyUploaded": true}
```

or

```json
{
  "uploadId": "...",
  "partSizeBytes": 67108864,
  "parts": [{"partNumber": 1, "url": "https://...presigned PUT..."}],
  "completedParts": [{"partNumber": 1, "etag": "\"...\""}],
  "urlsExpireAt": "..."
}
```

- `parts` covers every part not yet uploaded. Part N is bytes
  `[(N-1) * partSizeBytes, min(N * partSizeBytes, bytes))`.
- PUT each part's bytes to its `url` with no auth header; keep the
  response's `ETag` header (quotes included).
- Calling again for the same file resumes the same upload:
  `completedParts` lists what S3 already has.
- URLs expire after 6 hours; call again for fresh ones.

### `POST /uploads/complete`
Body: `{"gameId", "recordingId", "fileName", "uploadId", "parts": [{"partNumber", "etag"}]}`
(all parts, in order) → `200 {"ok": true}`

## Storage and processing hand-off

- Bucket keys: `accounts/<accountId>/games/<gameId>/recordings/<recordingId>/`
  - `manifest.json`
  - `<deviceId>/<fileName>`, the manifest's `objectKey` relative path.
- When the manifest is present, every device's segments are known, and
  every segment is in the bucket, the server writes the merged
  `manifest.json` (every device with its segments) and the recording
  becomes `ready`. Processing never sees a partial manifest. It becomes
  `ready` once, except when a Secondary Main left out reports later
  (`PUT .../report`): then it is `ready` a second time, with both phones. An
  EventBridge event is published on the default bus:
  - `source`: `opensportsball`
  - `detail-type`: `RecordingReady`
  - `detail`: `{"accountId", "gameId", "recordingId", "bucket", "prefix", "manifestKey"}`

  Phase 3 (processing) subscribes to this event.
- Incomplete multipart uploads are aborted after 7 days.
- Deleting a recording or game (website routes above) removes its prefix.
  The table keeps a small `DELETED#` marker for it so late uploads are
  refused. A recording deleted while processing runs may get outputs
  written back afterwards; processing should stop when the manifest is
  gone.
