// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as cdk from 'aws-cdk-lib';
import { OpenSportsBallStack } from '../lib/stack.js';

const app = new cdk.App();
const ctx = (key: string) => app.node.tryGetContext(key) as string | undefined;

const account = process.env.CDK_DEFAULT_ACCOUNT;
// Cognito login domains are global; default to one derived from the account.
const authDomainPrefix = ctx('authDomainPrefix') ?? (account ? `opensportsball-${account}` : 'opensportsball-dev');

new OpenSportsBallStack(app, ctx('stackName') ?? 'OpenSportsBall', {
  env: { account, region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1' },
  repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), '..', '..'),
  authDomainPrefix,
  devOrigins: (ctx('devOrigins') ?? 'http://localhost:5173').split(',').filter(Boolean),
  siteDomain: ctx('siteDomain'),
  siteCertArn: ctx('siteCertArn'),
  description: 'OpenSportsBall: phone recording uploads, accounts and website',
});
