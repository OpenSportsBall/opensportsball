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

**People, on the website.** Sign in with the Cognito hosted login
(authorization code + PKCE). Calls carry `Authorization: Bearer <Cognito
access token>`. The account id is the token's `sub`.

**Phones.** A phone is linked to an account once, by scanning a QR code
shown on the website. Linking returns a long-lived device token
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
(`401`). A phone can hold grants from several accounts at once.

## Website config

The deployed site serves `/config.json`:

```json
{
  "apiUrl": "https://abc123.execute-api.us-east-1.amazonaws.com",
  "region": "us-east-1",
  "userPoolId": "us-east-1_XXXX",
  "userPoolClientId": "xxxxxxxx",
  "cognitoDomain": "https://opensportsball-xxxx.auth.us-east-1.amazoncognito.com"
}
```

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
→ `200 {"games": [{"gameId", "createdAt", "recordingCount", "status"}]}`,
newest first. `status` is the least-finished status of its recordings.

### `GET /games/{gameId}`
→ `200`

```json
{
  "gameId": "...",
  "createdAt": "...",
  "recordings": [
    {
      "recordingId": "...",
      "createdAt": "...",
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

## Routes for phones

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
  becomes `ready` (once). Processing never sees a partial manifest. An
  EventBridge event is published on the default bus:
  - `source`: `opensportsball`
  - `detail-type`: `RecordingReady`
  - `detail`: `{"accountId", "gameId", "recordingId", "bucket", "prefix", "manifestKey"}`

  Phase 3 (processing) subscribes to this event.
- Incomplete multipart uploads are aborted after 7 days.
