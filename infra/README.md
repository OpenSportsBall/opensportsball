# infra

AWS CDK (TypeScript) stack: accounts, phone linking, uploads, the website,
and cloud processing on AWS Batch. License: Apache-2.0.

## What it creates

| Resource | Purpose | Cost when idle |
|---|---|---|
| S3 `Footage` bucket | Raw segments and manifests, under `accounts/<id>/games/...` | storage only |
| DynamoDB table (on-demand) | Devices, link codes, games, recordings, upload state | storage only |
| Cognito user pool + managed login | Website sign-up and sign-in, styled like the site (`lib/login-branding.ts`) | free tier |
| HTTP API + 4 Lambdas (Node 22, arm64) | `docs/API.md` | none |
| S3 `Site` bucket + CloudFront | The website (`web/build`) and its `config.json` | ~none |
| CloudFront `FootageCdn` (with a signing key) | Footage downloads with signed URLs only ("Footage downloads") | none |
| S3 `Contributions` bucket | Results users share to improve the models, under `contributions/<id>/...` (`docs/API.md`, "Contributions") | storage only |
| EventBridge rules → CloudWatch Logs | Record `RecordingReady`, so a finished upload is visible, and `ContributionReady` until training does | none |
| VPC (public subnets, no NAT gateway, S3 gateway endpoint) | Where processing runs | none |
| Batch: a Spot GPU compute environment (`g5.xlarge` / `g6.xlarge`, 0 to 8 vCPUs) and a Fargate one, a queue each, job definitions `prepare` / `run` / `refit` | Cloud processing ("Cloud processing" below) | none: both scale to zero |
| ECR repository | The engine's image | cents a month |
| EventBridge rule → `JobEvents` Lambda | Follows Batch job state changes and emails the account | none |

Nothing runs between games. Footage storage is the main cost (about
$0.023/GB-month). Uploads and what processing makes from them (`outputs/`)
expire after 180 days; processing checkpoints (`work/`) after 7.

The footage and contributions buckets, table and user pool are
**retained** if the stack is deleted, so a mistaken `cdk destroy` can't
delete recordings, shared results or accounts. Shared results don't expire
with footage: they stay until the user withdraws them, deletes the
account, or the account goes unused for 3 years (a sweep still to build,
docs/BACKLOG.md), unless `contributionRetentionDays` is set.

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
| `siteDomain` | none | Serve the website at this domain; `www.<domain>` and the CloudFront address redirect to it |
| `siteCertArn` | none | ACM certificate **in us-east-1** for `siteDomain` and `www.<siteDomain>` (required with `siteDomain`) |
| `authDomain` | none | Serve the sign-in pages at this domain, e.g. `auth.example.com`, instead of the Cognito prefix domain |
| `authCertArn` | none | ACM certificate **in us-east-1** for `authDomain` (required with `authDomain`) |
| `footageSigningPublicKeyFile` | `footage-signing-public.pem` | Public key for footage download URLs, relative to `infra/` ("Footage downloads") |
| `contributionRetentionDays` | none (kept until withdrawn) | Expire shared results this many days after upload; the privacy policy must say the same |
| `engineImageTag` | `stub` | Tag of the engine image in the stack's repository ("Cloud processing") |
| `engineCompute` | `cpu` | Where `prepare` and `run` go: `cpu` (Fargate, enough for the stub engine) or `gpu` (Spot `g5.xlarge` / `g6.xlarge`, for the real engine) |
| `gpuSpot` | `true` | `false` runs the GPU jobs on On-Demand instances instead of Spot (about twice the price, never reclaimed), for an account whose Spot quota for G instances is still 0 |
| `emailFrom` | none | Sender of the processing emails, e.g. `OpenSportsBall <no-reply@example.com>`; an address or domain verified in SES. None are sent without it |

### Deployment settings

A deployment's own settings (`siteDomain`, `siteCertArn`, `authDomain`,
`authCertArn`, and any others above) go in `infra/cdk.context.json`, which
is git-ignored, or on the command line with `-c`. `cdk.json` holds only
defaults shared by every deployment, so a fresh checkout deploys a stack
with no custom domains. For example:

```json
{
  "siteDomain": "example.com",
  "siteCertArn": "arn:aws:acm:us-east-1:<account>:certificate/<id>",
  "authDomain": "auth.example.com",
  "authCertArn": "arn:aws:acm:us-east-1:<account>:certificate/<id>"
}
```

Keep a copy of this file somewhere safe: deploying an existing stack
without it removes the stack's custom domains (synth prints a warning when
none are set). The certificate ARNs can be found again with
`aws acm list-certificates --region us-east-1`. Avoid `cdk context
--clear`, which empties the file.

### Footage downloads

Footage leaves the bucket through a second CloudFront distribution,
`FootageCdn`, not straight from S3: CloudFront's first 1 TB a month is
free, and S3 to CloudFront costs nothing. It serves only URLs (or cookies)
signed by the website API (`api/src/lib/footageUrls.ts`), which signs an
account's own recordings, and those a footage link was made for
(`docs/API.md`, "Footage links"). Nothing is cached, so a deleted recording is gone
from CloudFront as soon as it is gone from S3. Every answer carries
`Content-Disposition: attachment`, so a link on the website saves the file.
Uploads still go straight to S3.

The distribution needs a key pair. Make it once per deployment, signed in
to the AWS account:

```
infra/scripts/footage-signing-key.sh [stack name]
cd infra && npx cdk deploy
```

The script puts the private key in SSM (SecureString
`/<stack name>/footage-signing-key`, never on disk) and writes the public
key to `infra/footage-signing-public.pem`, which is git-ignored like
`cdk.context.json`. Keep a copy of it with that file: deploying without it
removes the distribution (synth prints a warning). To change keys, run the
script again and deploy straight away; URLs signed with the old key stop
working.

### Cloud processing

The user starts a job from a game's page; the API submits AWS Batch jobs
that run the engine's container (`docs/CLOUD-PROCESSING-PLAN.md`, and
`docs/API.md` for the routes and for what the container is given and must
write). The engine itself is in the opensportsball-processing repository.
Until its image exists, `stub-engine/` stands in: it keeps the container's
side of the contract with a drawn pitch, made-up kit groups and a
3-second test-pattern video, and reads no footage.

To try it end to end:

1. Deploy (above). The stack's `EngineRepositoryUri` output is where the
   image goes.
2. Build and push the stub, signed in to the AWS account, with Docker
   running:

   ```
   infra/scripts/push-stub-engine.sh [stack name]
   ```

3. On the website's Admin page, open your account and switch **Cloud
   processing** on. Sign out and in, or reload, to see it.
4. On a game with a `Ready` recording, press **Process in the cloud**. The
   first Fargate task takes a minute or two to start; the stub then takes
   about 20 seconds a step. Answer the two checks, and the video appears
   on the game's page.

The footage distribution ("Footage downloads") must be set up: the
checks' pictures and the video are served through it.

For the real engine, build and push its image from the
opensportsball-processing repository (`packaging/cloud/build_image.sh
<tag> <EngineRepositoryUri>`), upload its models to the footage bucket's
`models/` prefix (that repository's `packaging/cloud/README.md`), and
deploy with `-c engineImageTag=<tag> -c engineCompute=gpu`. `prepare` and
`run` then go to the GPU queue; refits stay on Fargate. That needs a Spot
quota for G instances in the region (8 vCPUs runs two games at once; the
GPU compute environment is capped there). Jobs log to the
stack's `…ProcessingLogs…` log group in CloudWatch, kept a month.

Costs while idle are nothing: no NAT gateway, both compute environments at
zero. A GPU job that cannot get an instance for 12 hours is failed and its
owner emailed, instead of waiting forever.

For the emails ("check the pitch", "your video is ready", "processing
failed"), verify a sender in SES and deploy with
`-c emailFrom='OpenSportsBall <no-reply@example.com>'`. A new SES account
is in the sandbox and can only send to verified addresses until AWS lifts
that.

### Custom domain

1. Request the certificate (CloudFront only uses us-east-1 certificates):
   `aws acm request-certificate --region us-east-1 --domain-name example.com --subject-alternative-names www.example.com --validation-method DNS`
2. Add the two validation CNAMEs from `aws acm describe-certificate` at your
   DNS provider and wait for the certificate to show `ISSUED`.
3. Deploy with `siteDomain` and `siteCertArn` set.
4. Point `example.com` and `www.example.com` at the `CdnDomain` output
   (`d….cloudfront.net`): a CNAME, or an alias / flattened CNAME at the apex. If the DNS provider is Cloudflare, leave these
   **DNS only** (grey cloud); CloudFront already does the caching and TLS.

### Custom sign-in domain

1. Request a certificate for it, in us-east-1 like the site's:
   `aws acm request-certificate --region us-east-1 --domain-name auth.example.com --validation-method DNS`
2. Add its validation CNAME and wait for `ISSUED`.
3. The parent domain (`example.com`) must already resolve; Cognito checks.
4. Deploy with `authDomain` and `authCertArn` set. Creating the domain
   takes a few minutes.
5. Point `auth.example.com` at the `LoginCdnDomain` output with a CNAME
   (**DNS only** on Cloudflare). Sign-in is down from the end of the deploy
   until this record resolves, so add it right away.

The Cognito prefix domain keeps working alongside it.

Region: `CDK_DEFAULT_REGION` from your AWS CLI profile, else `us-east-1`.

## Test

```
npm test       # synthesizes the stack and checks routes, auth, storage settings
npx cdk synth  # writes the CloudFormation template to cdk.out/
```

Synthesis bundles the Lambda handlers from `api/` with `api/`'s esbuild, so
run `npm ci` in `api/` first.
