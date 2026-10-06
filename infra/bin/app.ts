// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as cdk from 'aws-cdk-lib';
import { SportsBallVideoStack } from '../lib/stack.js';

const app = new cdk.App();
const ctx = (key: string) => app.node.tryGetContext(key) as string | undefined;

const account = process.env.CDK_DEFAULT_ACCOUNT;
// Cognito login domains are global; default to one derived from the account.
const authDomainPrefix = ctx('authDomainPrefix') ?? (account ? `sportsballvideo-${account}` : 'sportsballvideo-dev');

new SportsBallVideoStack(app, ctx('stackName') ?? 'SportsBallVideo', {
  env: { account, region: process.env.CDK_DEFAULT_REGION ?? 'us-east-1' },
  repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), '..', '..'),
  authDomainPrefix,
  devOrigins: (ctx('devOrigins') ?? 'http://localhost:5173').split(',').filter(Boolean),
  description: 'SportsBallVideo: phone recording uploads, accounts and website',
});
