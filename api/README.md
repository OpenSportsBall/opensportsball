# api

Lambda handlers for the HTTP API in [`docs/API.md`](../docs/API.md).
TypeScript on Node 22, AWS SDK v3. License: Apache-2.0. Deployed by
[`infra/`](../infra/).

| Handler | Routes / trigger |
|---|---|
| `src/handlers/web.ts` | Website routes (Cognito JWT): `/me`, `/link-codes`, `/devices`, `/games` |
| `src/handlers/device.ts` | Phone routes: `/devices/link` (link code is the credential), recording grants, manifest and report upload, multipart uploads |
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
