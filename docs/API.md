# OpenSportsBall API (v1)

The contract between the phones, the website and the backend (`api/`,
`infra/`). Change all sides together.

## Basics

- Base URL: the API Gateway HTTP API URL, published to the website in
  `/config.json` (below) and to phones in the link QR code.
- JSON in and out, `Content-Type: application/json`.
- Errors: HTTP status plus `{"error": "<code>", "message": "<text>"}`.
  Codes used: `bad_request`, `unauthorized`, `forbidden`, `not_found`,
  `gone`, `conflict`, `invalid_manifest`, `invalid_contribution`, `internal`.
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
  "desktopClientId": "zzzzzzzz",
  "cognitoDomain": "https://opensportsball-xxxx.auth.us-east-1.amazoncognito.com"
}
```

`appClientId` is the phone app's Cognito client ("Signing in from the
app"), `desktopClientId` the Mac app's ("Signing in from the Mac app");
the website ignores both.

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

## Signing in from the Mac app

The Mac app (desktop/) signs in the same way with client
`desktopClientId` and redirect `opensportsball://desktop-auth`, but keeps
the Cognito tokens (in the Keychain) and calls the people routes with
them: `GET /games`, `GET /games/{gameId}`, `POST .../downloads`, and the
contributions. Its refresh token lasts 30 days, like the website's, so a
game can be downloaded and processed overnight without signing in again.

The `osb` command (packages/osb_core, `bin/osb.dart`) is the same client
with no window: `osb sign-in` opens managed login in the person's own
browser and listens on this computer for the answer, at
`http://localhost:<port>/callback` on the first free port of 47161-47163
(the Desktop client allows exactly those). It keeps its tokens in a file
only its owner can read, apart from the app's, and calls the same routes
(`osb games`, `osb game`, `osb download`).

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
→ `200 {"accountId": "...", "email": "...", "admin": false, "cloudProcessing": false}`

`admin` is true when the user is in the Cognito `admins` group (the
website then shows its Admin page). `cloudProcessing` is true when an
admin has switched cloud processing on for the account
(`PUT /admin/accounts/{accountId}/cloud-processing`).

### `DELETE /me`
Deletes the account and everything in it for good. → `204`

- Unlinks every phone (their tokens stop working: `401`), revokes the
  grant tokens and tickets the account handed out, stops its processing
  jobs, removes everything under `accounts/<accountId>/` (aborting open
  multipart uploads) and what processing made from it
  (`outputs/<accountId>/`, `work/<accountId>/`), deletes every table item
  of the account and its job records, then the Cognito user.
- Leaves one `ACCOUNT#<accountId> / CLOSED` item (the id and when), so a
  link code made before the delete answers `410 gone` and a segment that
  lands afterwards is deleted, instead of either starting the account
  again.
- Again after a partial failure finishes it: `204`.

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
is the least-finished status of its recordings, or null when it has none
(all deleted).

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
      ],
      "job": null
    }
  ]
}
```

`job` is the recording's newest processing job ("Processing jobs" below),
or null when it was never processed.

Before the manifest arrives, `devices` lists only phones that have
uploaded something, with `role`, `model`, `expectedSegments` and
`expectedBytes` null. After it arrives, a phone that has not reported its
segments yet has `expectedSegments` and `expectedBytes` null.

### `POST /games/{gameId}/recordings/{recordingId}/downloads`
Signed links for downloading a recording's footage, e.g. for processing
on your own computer. → `200`

```json
{
  "gameId": "...",
  "recordingId": "...",
  "status": "waiting_for_manifest | uploading | ready",
  "expiresAt": "...",
  "manifestUrl": "https://<footage CDN>/accounts/.../manifest.json?Expires=...&Signature=...&Key-Pair-Id=... | null",
  "files": [
    {
      "deviceId": "...", "fileName": "<deviceId>_000.mp4",
      "bytes": 1100000000, "sha256": "... | null",
      "url": "https://<footage CDN>/accounts/.../<deviceId>/<deviceId>_000.mp4?Expires=..."
    }
  ]
}
```

- Every segment that has arrived, whether or not the recording is
  complete: check `status` (`ready` means everything is there). `sha256` is
  what the phone listed for that file, or null when no manifest or report
  has listed it yet (or it listed another size); check it after
  downloading.
- `manifestUrl` is the merged manifest (both phones' segments), written
  when the recording turns `ready`; null before that.
- Links work for 12 hours (`expiresAt`), with plain `GET`s, including
  range requests for resuming. Ask again for fresh ones. They are served
  by the footage CloudFront distribution (infra/README.md, "Footage
  downloads"), never straight from S3.
- `404 not_found`: no such recording on the account (another account's,
  or deleted). `503 downloads_unavailable`: this deployment has no footage
  distribution.

### `DELETE /games/{gameId}/recordings/{recordingId}`
Deletes one recording for good. → `204`

- Removes everything under
  `accounts/<accountId>/games/<gameId>/recordings/<recordingId>/` in the
  bucket (manifest, segments), aborting multipart uploads still open
  there, and the recording's items: the recording and its manifest, each
  phone's report, uploaded-file and upload-in-progress records. The game
  and its other recordings stay.
- Processing goes with it: a job still running is stopped, the job records
  are deleted, and so is everything under the matching `outputs/...` and
  `work/...` folders (questions, answers, the game video, checkpoints).
- Phones are refused from then on (`410 gone`, below).
- Calling it again for a deleted recording is `204` (it finishes a delete
  that failed partway). `404 not_found`: no such recording on the account,
  including another account's.

### `DELETE /games/{gameId}`
Deletes a game and all its recordings for good. → `204`

- Removes everything under `accounts/<accountId>/games/<gameId>/`
  (aborting open multipart uploads), every recording's items, jobs and
  processing output as above, the game's grant records, and website
  tickets for it not yet redeemed.
- Grant tokens already on a Secondary are left to expire (14 days), so
  that phone is told the game was deleted (`410`) rather than that it was
  signed out (`401`).
- Again for a deleted game is `204`; `404 not_found` as above.

## Contributions (Cognito token)

Results a user agreed to share to improve the models, made by the
processing engine on their own computer (`engine.py share` in
opensportsball-processing) and uploaded by the Mac app: a pitch map, kit
groups, a ball label set, must-see moments. Kept apart from footage (their
own bucket), not deleted with the game they came from, deleted when the
user withdraws them, deletes the account, or the account goes unused for 3
years (privacy policy; the inactivity sweep is in docs/BACKLOG.md). Used only
inside the project, never published. The consent
wording the user accepted is stored with each one: `shared/consent/<version>.md`.
The Mac app shows that wording before the first send, then sends each
result as it is made or changed (withdrawing the copy it replaces) and
keeps what it sent in the game's `engine/share/sent.json`.

### `POST /contributions`
Starts one upload. → `201`

```json
{
  "gameId": "...",
  "recordingId": "...",
  "consentVersion": "share-v1",
  "contribution": { "...": "the engine's file, shared/schemas/engine-contribution.schema.json" }
}
```

Response: the contribution (as in `GET /contributions`, `status:
"uploading"`) plus `expiresAt` and `uploads`, one per listed file:
`{"path", "url", "headers"}`. `PUT` each file's bytes to its `url` with
exactly those `headers` (`x-amz-checksum-sha256`, `content-length`): the
URL is signed for the file's size and SHA-256, and S3 refuses other bytes.
Links last as long as upload links (6 hours); start again for fresh ones.

- `400 bad_request`: unknown `consentVersion`, a path that isn't a plain
  relative path (no `..`, no leading or trailing `/`), a file listed
  twice, more than 2000 files, a file over 50 MB or 500 MB in all, or a
  contribution from another game than `gameId`.
- `400 invalid_contribution`: the contribution doesn't match the schema
  (`details` lists why).
- `404 not_found`: no such recording on the account.

### `POST /contributions/{contributionId}/complete`
Checks every file arrived with its size and checksum, stores the
contribution file beside them, marks it `complete`, and publishes
`ContributionReady` (below). → `200` with the contribution. Again when
already complete: `200`. `409 conflict` with `details.missing` (up to 50
paths) when files are missing or differ.

### `GET /contributions`
→ `200` `{"contributions": [...]}`, newest first:

```json
{
  "contributionId": "...", "gameId": "...", "recordingId": "...",
  "kind": "pitch | kits | ball | moments", "name": "pitch | ball-1 | ...",
  "engineVersion": "...", "consentVersion": "share-v1",
  "status": "uploading | complete", "files": 7, "bytes": 10400000,
  "createdAt": "...", "completedAt": "... | null"
}
```

### `DELETE /contributions/{contributionId}`
Withdraws it: its files and record are deleted, for good. → `204`.
`404 not_found`: no such contribution on the account.

Storage: the contributions bucket, `contributions/<accountId>/<contributionId>/`
holds `contribution.json` (the ids, consent version and the engine's file)
and `files/<path>`. On `complete` an EventBridge event goes to the default
bus: `source` `opensportsball`, `detail-type` `ContributionReady`, `detail`
`{"accountId", "contributionId", "kind", "bucket", "prefix"}`. Deleting the
account (`DELETE /me`) deletes everything under `contributions/<accountId>/`.

## Processing jobs (Cognito token)

A job is one attempt to turn a `ready` recording into the followed game
video: in the cloud (AWS Batch), or on the user's own computer, where the
app that runs it writes the same record. The plan is in
[CLOUD-PROCESSING-PLAN.md](CLOUD-PROCESSING-PLAN.md). The job's shape is
`shared/schemas/job.schema.json`; the questions and answers are the
engine's own files (`engine-questions`, `engine-answers`), the ones the
Mac app draws, passed through.

A cloud job is two Batch jobs with the user in between:

```
queued -> preparing -> needs_answers -> queued -> running -> done
                        ^        |
                        +- refitting   (the engine works on an answer and asks again)
```

`failed` and `cancelled` end it from any state. `phase` (`prepare` or
`run`) tells the two `queued` states apart. A recording has at most one
job that has not ended.

The job, as every route here returns it:

```json
{
  "schemaVersion": 1,
  "jobId": "...", "gameId": "...", "recordingId": "...",
  "where": "cloud | local",
  "status": "queued | preparing | needs_answers | refitting | running | done | failed | cancelled",
  "phase": "prepare | run",
  "checks": {"cameras": "open | answered", "pitch": "open | answered", "kits": "open | answered"},
  "progress": {"stage": "ball", "fraction": 0.4, "etaSeconds": 5400, "at": "..."},
  "error": {"code": "footage_corrupt", "message": "..."},
  "stale": false,
  "engineVersion": "... | null",
  "createdAt": "...", "updatedAt": "...", "finishedAt": "... | null"
}
```

- `checks` are the engine's questions and whether each is still open.
  `cameras` is there only when the engine asked it (the two phones' views
  couldn't be stitched), and is answered before the other two. The engine
  decides what is open: after each prepare or refit the server reads
  `pending` from its questions.
- `progress` and `error` are null when there is none. `error.code` is the
  engine's own (e.g. `footage_corrupt`, `not_enough_disk`) or one of the
  server's: `engine_failed`, `engine_no_result` (it ended without its
  questions or video), `machine_failed` (a Spot instance was reclaimed too
  many times, or the job could not be submitted), `no_machine` (none
  became free in 12 hours), `timed_out`, `superseded` (below).
- `stale` is true when the recording became `ready` again after the job
  started: a second phone's footage arrived, and the job did not see it.
  A job still going when that happens is cancelled with `superseded`; a
  finished one is kept, and nothing is processed again unasked.

### `POST /games/{gameId}/recordings/{recordingId}/jobs`
Body: `{"where": "cloud"}` or `{"where": "local"}` → `201` the job.

- `cloud` submits the prepare job (`status: queued`). `local` only makes
  the record (`status: preparing`); the app then reports with
  `PUT .../status`.
- `403 cloud_not_enabled`: `cloud` on an account without
  `cloudProcessing`. `503 cloud_unavailable`: this deployment has no cloud
  processing, or Batch refused the job (the job is then `failed`).
- `409 conflict`: the recording is not `ready`, or already has a job that
  has not ended. `404 not_found`: no such recording on the account.

### `GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}`
→ `200` the job. `404 not_found`: no such job on that recording of the
account.

### `DELETE /games/{gameId}/recordings/{recordingId}/jobs/{jobId}`
Cancels a job that has not ended, stopping its Batch job. → `204`.
`409 conflict`: it has already ended.

### `GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/questions`
The engine's questions, once it has written them. → `200`

```json
{
  "status": "needs_answers",
  "checks": {"pitch": "open", "kits": "open"},
  "expiresAt": "...",
  "questions": { "schemaVersion": 1, "pending": ["pitch", "kits"], "pitch": {...}, "kits": {...} }
}
```

- `questions` is the engine's `questions.json`
  (`shared/schemas/engine-questions.schema.json`), unchanged except that
  every field naming a picture (`image`, `overlay`, `background`, `sheet`,
  `mainLeft`, `secondaryLeft`) gets a signed link next to it: `imageUrl`,
  `overlayUrl` and so on, good until `expiresAt` (12 hours). A path that
  points outside the questions folder gets null.
- Angles are panorama degrees. `pitch.panorama` says how they map to the
  background picture's pixels.
- `409 conflict`: no questions yet. `503 downloads_unavailable`: no footage
  distribution.

### `PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/answers`
Answers one question. Body: `"question": "cameras"`, `"pitch"` or
`"kits"`, plus that question's answer from
`shared/schemas/engine-answers.schema.json`. → `200` the job.

```json
{"question": "pitch", "round": 1, "approve": true}
{"question": "pitch", "round": 1,
 "points": {"left corner flag": {"yaw": -79.2, "pitch": 21.0},
            "right corner flag": {"skipped": true}, "halfway far end": {"fromFit": true}}}
{"question": "kits", "round": 1, "tapped": {"0": ["c0_07"]}}
{"question": "kits", "round": 1, "merge": [[0, 7], [1, 2]], "keeperOrReferee": [5, 6], "notKit": [3, 4]}
{"question": "kits", "round": 1, "split": 3}
{"question": "cameras", "round": 1, "leftPhone": "secondary"}
```

- `round` is the `round` of the question being answered.
- An approved pitch, or kit groups without a split, close that check
  here. When none is open the run job is submitted (`status: queued`,
  `phase: run`), and the engine applies the answers before it starts. If
  it will not use one (for example fewer than two kit groups are left),
  it writes its questions again with the reason in `problem`, and the job
  returns to `needs_answers`.
- Pitch points, a group to split, or the cameras submit a refit
  (`status: refitting`): the engine redraws and asks again with the next
  `round`. If nothing is left to ask afterwards, the run starts by itself.
- `share` (pitch and kits: whether the user agrees to share the result to
  improve the models) is recorded as false unless the body says true.
- The answers are kept as `answers.json` in the job's output folder, as
  the engine reads them.
- `400 invalid_answers`: it does not match the schema, names a point,
  group or person the question does not have, approves a pitch that must
  be marked first (`approveAllowed: false`), or splits a second time.
  `409 conflict`: the job is not waiting for answers, the check is already
  answered or not asked yet, or `round` is not the current one (reload the
  questions). `403 forbidden`: a local job, which is answered in its app.
  `503 cloud_unavailable`: the next Batch job could not be submitted; the
  job goes back to `needs_answers`.

### `PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/status`
For the app running a local job. Body: `{"status", "progress"?, "error"?,
"engineVersion"?}`, with `status` one of `preparing`, `needs_answers`,
`refitting`, `running`, `done`, `failed`. → `200` the job.
`403 forbidden`: a cloud job. `409 conflict`: the job has ended.

### `POST /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/downloads`
A signed link to the finished game video. →
`200 {"expiresAt", "video": {"url", "bytes", "fileName": "game.mp4"}}`.
The link works for 12 hours, range requests included (so it plays in a
`<video>`). `409 conflict`: the job is not `done`. `404 not_found`: the
video has expired or been deleted.

## Admin routes (Cognito token, `admins` group)

A Cognito token whose `cognito:groups` includes `admins`; anyone else gets
`403 forbidden`. Group membership is read from the token, so a user added
to the group must sign in again.

### `GET /admin/accounts`
→ `200`

```json
{
  "generatedAt": "...",
  "totals": {"accounts": 4, "deletedAccounts": 3, "devices": 5, "games": 18,
             "recordings": 32, "storageBytes": 498900000000, "objectCount": 449},
  "accounts": [
    {
      "accountId": "...", "email": "... | null",
      "status": "active | disabled | unconfirmed | deleted | no_sign_in",
      "createdAt": "... | null",
      "devices": [{"deviceId", "platform", "model", "linkedAt", "lastSeenAt"}],
      "games": 3,
      "recordings": {"total": 5, "waiting_for_manifest": 1, "uploading": 2, "ready": 2},
      "cloudProcessing": false,
      "storageBytes": 81800000000, "objectCount": 73,
      "lastUploadAt": "... | null", "oldestObjectAt": "... | null"
    }
  ]
}
```

- One row per Cognito user, plus any account id that has table items or
  footage but no user (`no_sign_in`), biggest storage first.
- Storage is everything under `accounts/<accountId>/` in the bucket;
  `lastUploadAt` and `oldestObjectAt` are its newest and oldest objects
  (the oldest is the next to expire).
- A deleted account (`DELETE /me`) is counted in `deletedAccounts`, and
  listed only while anything of it is left.
- Reads the whole table, the user pool and the bucket listing each call:
  fine for an admin page, not for anything hit often.

### `GET /admin/accounts/{accountId}/games`
→ `200 {"accountId", "email": "... | null", "games": [...]}`, newest first:

```json
{
  "gameId": "...", "createdAt": "... | null", "recordedAt": "... | null",
  "inTable": true, "storageBytes": 29400000000, "objectCount": 30,
  "recordings": [
    {"recordingId": "...", "createdAt": "... | null", "recordedAt": "... | null",
     "status": "waiting_for_manifest | uploading | ready | null", "hasManifest": true,
     "storageBytes": 14700000000, "objectCount": 15, "lastUploadAt": "... | null"}
  ]
}
```

Footage in the bucket with no table record is listed too: its game has
`inTable: false` and its recordings `status: null`.

### `DELETE /admin/accounts/{accountId}/games/{gameId}`
### `DELETE /admin/accounts/{accountId}/games/{gameId}/recordings/{recordingId}`
Deletes another account's game or recording exactly as its owner would
(`DELETE /games/...` above, including the `410` for phones afterwards),
and also footage the table has no record of. → `204`; `404 not_found`
when there is neither a record nor footage. Each one logs an audit line
(admin's account id, action and ids) in the admin Lambda's logs, kept for
a month.

### `PUT /admin/accounts/{accountId}/cloud-processing`
Body: `{"enabled": true}` or `{"enabled": false}` →
`200 {"accountId", "cloudProcessing"}`. Lets the account start cloud
processing jobs, or stops it from starting more (jobs already running
carry on). Logs an audit line like the deletes.

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
- `404 not_found`: no such code. `410 gone`: expired or already used, or
  the account was deleted.
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
The ticket is the credential, as the code is for linking. Binds a ticket
to one game and phone; from then on the ticket is that phone's grant for
that game (14 days, as `POST /games/{gameId}/grants`). A grant uploads
under the same keys as that phone's own uploads, so binding it to a phone
linked to the ticket's account also takes a device token of that account
(`Authorization: Bearer osbd_...`); without one, anyone holding the
ticket could name Main's phone and overwrite its footage.
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
  `403 forbidden`: binding it to a phone linked to the ticket's account
  without a device token of that account.

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

  Nothing starts on this event: the user starts cloud processing from the
  website ("Processing jobs" above). It is only logged. When a recording
  becomes `ready` a second time, a job still going on the first manifest
  is cancelled before the event is published.
- Incomplete multipart uploads are aborted after 7 days.
- Deleting a recording or game (website routes above) removes its prefix
  and the matching `outputs/` and `work/` folders, and stops its jobs. The
  table keeps a small `DELETED#` marker for it so late uploads are
  refused. An engine that was mid-write may still put a file back
  afterwards: it should stop when the manifest is gone, and the lifecycle
  rules below remove what it leaves.
- What processing writes is kept apart from the uploads, under the same
  path below another root:
  - `outputs/<accountId>/games/<gameId>/recordings/<recordingId>/jobs/<jobId>/`:
    `questions/questions.json` and its images, `answers.json`, `game.mp4`.
    Expires 180 days after it is written.
  - `work/.../jobs/<jobId>/`: the engine's checkpoints. Expires after 7 days.

## The engine's container

Cloud processing runs one container image, the engine's, as AWS Batch
jobs. This repository never contains the engine
([LICENSING.md](LICENSING.md)): the two agree on what follows, and on the
`engine-*` files in `shared/schemas/`. The real one is
opensportsball-processing's `processing/spikes/cloud.py` and
`packaging/cloud/`; `infra/stub-engine/` is a stand-in that keeps the same
contract and reads no footage.

The container is started with one argument, `prepare`, `refit` or `run`,
and these variables:

| Variable | Value |
|---|---|
| `OSB_COMMAND` | The same as the argument |
| `OSB_JOB_ID` | The job's id |
| `OSB_BUCKET`, `OSB_TABLE` | The footage bucket and the table |
| `OSB_FOOTAGE_PREFIX` | `accounts/.../recordings/<recordingId>/`: `manifest.json` and the segments (read only) |
| `OSB_OUTPUT_PREFIX` | `outputs/.../jobs/<jobId>/` (read and write) |
| `OSB_WORK_PREFIX` | `work/.../jobs/<jobId>/` (read and write) |
| `OSB_REQUIRE_GPU` | `1` on the GPU queue: stop at once (`no_gpu`) rather than work without one |

Its role can read `accounts/` and `models/`, read and write `outputs/`
and `work/`, and get and update table items whose partition key starts
with `JOB#`. On the GPU queue it has one GPU, 4 vCPUs, 14 GB of memory and
a 200 GB scratch disk at `/scratch`.

What each command must leave behind, and how it ends:

| Command | Reads | Must write under the output prefix | Time limit |
|---|---|---|---|
| `prepare` | the manifest and footage | `questions/questions.json` (engine-questions) and every picture it names, at `questions/<its path>` | 1 hour |
| `refit` | `answers.json` (engine-answers), and what it kept in `work/` | `questions/questions.json` again | 15 minutes |
| `run` | the footage and `answers.json` | `game.mp4` (and `result.json`: the engine's done event); or `questions/questions.json` again, if it will not use an answer | 12 hours |

`pending` in the questions is what the server goes by: after `prepare` or
`refit`, an empty list starts the run; after a `run` that left no video,
a non-empty one sends the job back to the user.

- **Exit 0** when the file is written. The server then looks for the file
  and moves the job on; exit 0 without it is `engine_no_result`.
- **Exit non-zero** on failure. To say why, set `error` (`{"code",
  "message"}`) on the job record first; otherwise the job fails as
  `engine_failed`.
- **Progress** (optional): `SET progress = {"stage", "fraction",
  "etaSeconds", "at"}`, and `engineVersion`, on the item
  `pk = JOB#<jobId>, sk = JOB`, with the condition `attribute_exists(pk)`
  so a deleted job is not written back. No more than every 30 seconds.
  The container sets nothing else on the record: `status` is the
  server's.
- **Spot:** on the GPU queue a reclaimed instance restarts the command, up
  to 5 attempts. Keep checkpoints in the work prefix and resume from
  them. Any other failure is not retried.
- **Deleted footage:** stop when `manifest.json` is gone.
