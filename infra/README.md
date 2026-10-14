# infra

AWS CDK (TypeScript) stack for Phase 2: accounts, phone linking, uploads
and the website. License: Apache-2.0.

## What it creates

| Resource | Purpose | Cost when idle |
|---|---|---|
| S3 `Footage` bucket | Raw segments and manifests, under `accounts/<id>/games/...` | storage only |
| DynamoDB table (on-demand) | Devices, link codes, games, recordings, upload state | storage only |
| Cognito user pool + hosted login | Website sign-up and sign-in | free tier |
| HTTP API + 4 Lambdas (Node 22, arm64) | `docs/API.md` | none |
| S3 `Site` bucket + CloudFront | The website (`web/build`) and its `config.json` | ~none |
| EventBridge rule → CloudWatch Logs | Records `RecordingReady` until Phase 3 consumes it | none |

Nothing runs between games. Footage storage is the main cost (about
$0.023/GB-month); Phase 3 adds the rule that deletes raw footage after
rendering.

The footage bucket, table and user pool are **retained** if the stack is
deleted, so a mistaken `cdk destroy` can't delete recordings or accounts.

## Deploy

Prerequisites: an AWS account, the AWS CLI signed in (`aws configure` or
`aws sso login`), Node 22+.

```
cd api && npm ci && cd ..
cd web && npm ci && npm run build && cd ..
cd infra && npm ci
npx cdk bootstrap        # once per account and region
npx cdk deploy
```

The outputs include `SiteUrl` (open it, sign up, link your phones on
the Devices page) and `ApiUrl`.

Options (pass with `-c key=value`):

| Context key | Default | Meaning |
|---|---|---|
| `stackName` | `OpenSportsBall` | CloudFormation stack name |
| `authDomainPrefix` | `opensportsball-<account id>` | Cognito login domain; globally unique |
| `devOrigins` | `http://localhost:5173` | Extra origins allowed for login callbacks and CORS (comma-separated) |
| `siteDomain` | none | Serve the website at this domain; `www.<domain>` redirects to it |
| `siteCertArn` | none | ACM certificate **in us-east-1** for `siteDomain` and `www.<siteDomain>` (required with `siteDomain`) |

To keep these between deploys, put them in `infra/cdk.context.json`
(git-ignored, since they're account-specific).

### Custom domain

1. Request the certificate (CloudFront only uses us-east-1 certificates):
   `aws acm request-certificate --region us-east-1 --domain-name example.com --subject-alternative-names www.example.com --validation-method DNS`
2. Add the two validation CNAMEs from `aws acm describe-certificate` at your
   DNS provider and wait for the certificate to show `ISSUED`.
3. Deploy with `siteDomain` and `siteCertArn` set.
4. Point `example.com` and `www.example.com` at the `CdnDomain` output
   (`d….cloudfront.net`): a CNAME, or an alias / flattened CNAME at the apex. If the DNS provider is Cloudflare, leave these
   **DNS only** (grey cloud); CloudFront already does the caching and TLS.

Region: `CDK_DEFAULT_REGION` from your AWS CLI profile, else `us-east-1`.

## Test

```
npm test       # synthesizes the stack and checks routes, auth, storage settings
npx cdk synth  # writes the CloudFormation template to cdk.out/
```

Synthesis bundles the Lambda handlers from `api/` with `api/`'s esbuild, so
run `npm ci` in `api/` first.
