# api

Lambda handlers behind API Gateway, with DynamoDB for state and Cognito for
auth. License: Apache-2.0. Not started (Phase 2).

Planned endpoints: device pairing / sign-in by QR code, create game and
session, presign S3 multipart uploads, accept the manifest and check it is
complete, job status, YouTube OAuth connect (refresh token encrypted with
KMS).

Never imports from `processing/` or `ml/`; the pipeline is triggered through
S3 and Step Functions only (docs/LICENSING.md rule 2).
