// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as cdk from 'aws-cdk-lib';
import { OpenSportsBallStack } from '../lib/stack.js';

const app = new cdk.App();
const ctx = (key: string) => app.node.tryGetContext(key) as string | undefined;

// A deployment's domains and certificates live in the git-ignored
// cdk.context.json, so a checkout without that file deploys with none.
// Deploying a stack that had them would then remove them.
if (!ctx('siteDomain') && !ctx('authDomain')) {
  console.warn(
    'No siteDomain or authDomain set (see infra/README.md, "Deployment settings"). ' +
      'If this stack was deployed with custom domains, this deploy removes them.',
  );
}

// The footage download key (infra/README.md, "Footage downloads"), also
// git-ignored: without it there is no footage distribution, and deploying
// a stack that had one removes it.
const infraDir = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const footageKeyFile = resolve(infraDir, ctx('footageSigningPublicKeyFile') ?? 'footage-signing-public.pem');
const footageSigningPublicKey = existsSync(footageKeyFile) ? readFileSync(footageKeyFile, 'utf8').trim() : undefined;
if (!footageSigningPublicKey) {
  console.warn(
    `No ${footageKeyFile}: no footage download distribution (see infra/README.md, "Footage downloads"). ` +
      'If this stack was deployed with one, this deploy removes it.',
  );
}

const engineCompute = ctx('engineCompute');
if (engineCompute !== undefined && engineCompute !== 'cpu' && engineCompute !== 'gpu') {
  throw new Error(`engineCompute must be "cpu" or "gpu", not "${engineCompute}"`);
}
const gpuSpot = ctx('gpuSpot');
if (gpuSpot !== undefined && gpuSpot !== 'true' && gpuSpot !== 'false') {
  throw new Error(`gpuSpot must be "true" or "false", not "${gpuSpot}"`);
}

const account = process.env.CDK_DEFAULT_ACCOUNT;
// Cognito login domains are global; default to one derived from the account.
const authDomainPrefix = ctx('authDomainPrefix') ?? (account ? `opensportsball-${account}` : 'opensportsball-dev');

new OpenSportsBallStack(app, ctx('stackName') ?? 'OpenSportsBall', {
  env: { account, region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1' },
  repoRoot: resolve(infraDir, '..'),
  footageSigningPublicKey,
  authDomainPrefix,
  devOrigins: (ctx('devOrigins') ?? 'http://localhost:5173').split(',').filter(Boolean),
  siteDomain: ctx('siteDomain'),
  siteCertArn: ctx('siteCertArn'),
  authDomain: ctx('authDomain'),
  authCertArn: ctx('authCertArn'),
  contributionRetentionDays: ctx('contributionRetentionDays') ? Number(ctx('contributionRetentionDays')) : undefined,
  engineImageTag: ctx('engineImageTag'),
  engineCompute: engineCompute as 'cpu' | 'gpu' | undefined,
  gpuSpot: gpuSpot === undefined ? undefined : gpuSpot === 'true',
  emailFrom: ctx('emailFrom'),
  description: 'OpenSportsBall: phone recording uploads, accounts and website',
});
