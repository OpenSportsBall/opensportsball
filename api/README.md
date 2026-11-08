# api

Lambda handlers for the HTTP API in [`docs/API.md`](../docs/API.md).
TypeScript on Node 22, AWS SDK v3. License: Apache-2.0. Deployed by
[`infra/`](../infra/).

| Handler | Routes / trigger |
|---|---|
| `src/handlers/web.ts` | Website routes (Cognito JWT): `/me`, `/link-codes`, `/devices`, `/games` |
| `src/handlers/device.ts` | Phone routes: `/devices/link` (link code is the credential), recording grants, manifest and report upload, multipart uploads |
| `src/handlers/admin.ts` | Admin routes (Cognito JWT, `admins` group): `/admin/accounts`, and listing and deleting any account's games and recordings. Its own Lambda, the only one that may scan the table and list users |
| `src/handlers/authorizer.ts` | Lambda authorizer for phone routes (device or grant token hash lookup, uncached) |
| `src/handlers/ingest.ts` | S3 `ObjectCreated` for segment files |

Shared logic is in `src/lib/`: `store.ts` (clients, config, the
single-table key layout), `recordings.ts` (when a recording becomes
`ready` and the `RecordingReady` hand-off), `manifest.ts` (schema from
`shared/schemas/` plus rules the schema can't express), `tokens.ts`,
`http.ts`.

The hand-off to processing happens exactly once: the switch to `ready` is a
conditional write, and if publishing the event fails the status is rolled
back so the next upload or manifest call retries it.

## Admin scripts

For the live stack, run from `api/` with AWS credentials (e.g.
`AWS_PROFILE=<profile>` after `aws sso login`). Table, bucket and region
come from `infra/cdk-outputs.json` unless `TABLE_NAME`, `BUCKET_NAME` or
`AWS_REGION` are set. Both print what they would do and change nothing
without `--yes`.

| Script | What it does |
|---|---|
| `scripts/delete-recording.ts` | Lists an account's games and recordings (`--account <acct>`), or deletes one recording (`--game <gameId> --recording <recId>`) or a whole game (`--game <gameId>`): footage and manifest in S3, unfinished multipart uploads, table items, and a game's grants and their tokens. Runs with `node` directly. |
| `scripts/import-recording.ts` | Imports a recording copied off the phones (a folder with the phone's `manifest.json` and `<deviceId>/<deviceId>_NNN.mp4` segments) into an account as if the phones had uploaded it: checks the manifest and each file's size and sha256, uploads the segments (`aws s3 cp`), records them with `recordObject`, and `checkReady` marks it `ready`. Skips files already in the bucket, so a stopped import can be rerun. Bundle it with esbuild first (see its header); `node` can't follow the `.js` imports of `src/` to their `.ts` files. |

To let someone use the website's Admin page (`GET /admin/accounts`), add
them to the `admins` group; they must sign out and in again to pick it up:

```
aws cognito-idp admin-add-user-to-group --user-pool-id <UserPoolId> --group-name admins --username <accountId>
```

An account id is the Cognito user's `sub`. To find it from an email:

```
aws cognito-idp list-users --user-pool-id <UserPoolId> --filter 'email = "<email>"' --query 'Users[].Username'
```

## Test

The tests run the handlers against **moto**, a local AWS emulator
(DynamoDB, S3 multipart and presigned URLs, EventBridge, SQS), so
conditional writes, transactions and real uploads are exercised:

```
pip install "moto[server]"     # or set MOTO_SERVER=/path/to/moto_server
npm ci
npm test
```

`npm run build` type-checks.
