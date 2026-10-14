// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as cdk from 'aws-cdk-lib';
import { Match, Template } from 'aws-cdk-lib/assertions';
import { beforeAll, describe, expect, it } from 'vitest';
import { OpenSportsBallStack } from '../lib/stack.js';

let t: Template;

beforeAll(() => {
  const app = new cdk.App({ context: { '@aws-cdk/customresources:installLatestAwsSdkDefault': false } });
  const stack = new OpenSportsBallStack(app, 'Test', {
    repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), '..', '..'),
    authDomainPrefix: 'osb-test',
    devOrigins: ['http://localhost:5173'],
  });
  t = Template.fromStack(stack);
}, 120_000);

const routes = () =>
  Object.values(t.findResources('AWS::ApiGatewayV2::Route')).map((r) => ({
    key: r.Properties.RouteKey as string,
    auth: r.Properties.AuthorizationType as string,
  }));

describe('API', () => {
  it('has exactly the documented routes, each with the right kind of auth', () => {
    expect(routes().sort((a, b) => a.key.localeCompare(b.key))).toEqual([
      { key: 'DELETE /devices/{deviceId}', auth: 'JWT' },
      { key: 'GET /devices', auth: 'JWT' },
      { key: 'GET /games', auth: 'JWT' },
      { key: 'GET /games/{gameId}', auth: 'JWT' },
      { key: 'GET /me', auth: 'JWT' },
      { key: 'POST /devices/link', auth: 'NONE' },
      { key: 'POST /devices/unlink', auth: 'CUSTOM' },
      { key: 'POST /games/{gameId}/grants', auth: 'CUSTOM' },
      { key: 'POST /link-codes', auth: 'JWT' },
      { key: 'POST /uploads', auth: 'CUSTOM' },
      { key: 'POST /uploads/complete', auth: 'CUSTOM' },
      { key: 'PUT /games/{gameId}/recordings/{recordingId}/manifest', auth: 'CUSTOM' },
      { key: 'PUT /games/{gameId}/recordings/{recordingId}/report', auth: 'CUSTOM' },
    ]);
  });

  it('the phone authorizer is never cached, so unlinking is immediate', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::Authorizer', {
      AuthorizerType: 'REQUEST',
      AuthorizerResultTtlInSeconds: 0,
      EnableSimpleResponses: true,
    });
  });

  it('is throttled', () => {
    t.hasResourceProperties('AWS::ApiGatewayV2::Stage', {
      DefaultRouteSettings: { ThrottlingBurstLimit: 50, ThrottlingRateLimit: 20 },
    });
  });

  it('runs every Lambda on Node 22 arm64', () => {
    const fns = Object.values(t.findResources('AWS::Lambda::Function')).filter(
      (f) => f.Properties.Environment?.Variables?.TABLE_NAME,
    );
    expect(fns).toHaveLength(4);
    for (const f of fns) {
      expect(f.Properties.Runtime).toBe('nodejs22.x');
      expect(f.Properties.Architectures).toEqual(['arm64']);
    }
  });
});

describe('storage', () => {
  it('footage bucket is private, encrypted, kept on stack delete, and cleans up abandoned uploads', () => {
    t.hasResource('AWS::S3::Bucket', {
      DeletionPolicy: 'Retain',
      Properties: Match.objectLike({
        PublicAccessBlockConfiguration: {
          BlockPublicAcls: true,
          BlockPublicPolicy: true,
          IgnorePublicAcls: true,
          RestrictPublicBuckets: true,
        },
        LifecycleConfiguration: {
          Rules: [Match.objectLike({ AbortIncompleteMultipartUpload: { DaysAfterInitiation: 7 } })],
        },
      }),
    });
  });

  it('table has TTL and point-in-time recovery, and is kept on stack delete', () => {
    t.hasResource('AWS::DynamoDB::GlobalTable', {
      DeletionPolicy: 'Retain',
      Properties: Match.objectLike({
        TimeToLiveSpecification: { AttributeName: 'ttl', Enabled: true },
        Replicas: [Match.objectLike({ PointInTimeRecoverySpecification: { PointInTimeRecoveryEnabled: true } })],
      }),
    });
  });

  it('new segment files trigger the ingest Lambda', () => {
    const [n] = Object.values(t.findResources('Custom::S3BucketNotifications'));
    const [cfg] = n!.Properties.NotificationConfiguration.LambdaFunctionConfigurations;
    expect(cfg.Events).toEqual(['s3:ObjectCreated:*']);
    expect(cfg.LambdaFunctionArn['Fn::GetAtt'][0]).toMatch(/^Ingest/);
    expect(cfg.Filter.Key.FilterRules).toEqual(
      expect.arrayContaining([
        { Name: 'prefix', Value: 'accounts/' },
        { Name: 'suffix', Value: '.mp4' },
      ]),
    );
  });
});

describe('accounts and website', () => {
  it('web login uses the code flow with the site and dev callbacks', () => {
    t.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      AllowedOAuthFlows: ['code'],
      GenerateSecret: false,
      CallbackURLs: Match.arrayWith(['http://localhost:5173/callback']),
    });
  });

  it('serves the site through CloudFront only', () => {
    t.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);
    t.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        DefaultRootObject: 'index.html',
        CustomErrorResponses: Match.arrayWith([Match.objectLike({ ErrorCode: 404, ResponseCode: 200, ResponsePagePath: '/index.html' })]),
      }),
    });
  });

  it('RecordingReady events are captured until processing exists', () => {
    t.hasResourceProperties('AWS::Events::Rule', {
      EventPattern: { source: ['opensportsball'], 'detail-type': ['RecordingReady'] },
    });
  });
});

describe('custom domain', () => {
  let d: Template;
  beforeAll(() => {
    const app = new cdk.App({ context: { '@aws-cdk/customresources:installLatestAwsSdkDefault': false } });
    const stack = new OpenSportsBallStack(app, 'TestDomain', {
      repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), '..', '..'),
      authDomainPrefix: 'osb-test',
      siteDomain: 'example.com',
      siteCertArn: 'arn:aws:acm:us-east-1:111111111111:certificate/test',
    });
    d = Template.fromStack(stack);
  }, 120_000);

  it('serves the apex and www with the certificate, redirecting www', () => {
    d.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: ['example.com', 'www.example.com'],
        ViewerCertificate: Match.objectLike({ AcmCertificateArn: 'arn:aws:acm:us-east-1:111111111111:certificate/test' }),
      }),
    });
    d.resourceCountIs('AWS::CloudFront::Function', 1);
  });

  it('login accepts the custom domain and the CloudFront address', () => {
    d.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      CallbackURLs: Match.arrayWith(['https://example.com/callback']),
    });
    const client = Object.values(d.findResources('AWS::Cognito::UserPoolClient'))[0];
    expect(client.Properties.CallbackURLs).toHaveLength(2);
  });
});
