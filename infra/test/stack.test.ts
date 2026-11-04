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
      { key: 'DELETE /games/{gameId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}/recordings/{recordingId}', auth: 'JWT' },
      { key: 'DELETE /me', auth: 'JWT' },
      { key: 'GET /devices', auth: 'JWT' },
      { key: 'GET /games', auth: 'JWT' },
      { key: 'GET /games/{gameId}', auth: 'JWT' },
      { key: 'GET /me', auth: 'JWT' },
      { key: 'POST /devices/link', auth: 'NONE' },
      { key: 'POST /devices/unlink', auth: 'CUSTOM' },
      { key: 'POST /games/{gameId}/grant-tickets', auth: 'JWT' },
      { key: 'POST /games/{gameId}/grants', auth: 'CUSTOM' },
      { key: 'POST /grant-tickets', auth: 'CUSTOM' },
      { key: 'POST /grants/lookup', auth: 'NONE' },
      { key: 'POST /grants/redeem', auth: 'NONE' },
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

describe('deleting footage', () => {
  /** The statements of the policy attached to the role of [fnPrefix]'s Lambda. */
  const statements = (fnPrefix: string) => {
    const [role] = Object.keys(t.findResources('AWS::IAM::Role')).filter((id) => id.startsWith(`${fnPrefix}ServiceRole`));
    return Object.values(t.findResources('AWS::IAM::Policy'))
      .filter((p) => p.Properties.Roles.some((r: { Ref: string }) => r.Ref === role))
      .flatMap((p) => p.Properties.PolicyDocument.Statement as Array<Record<string, any>>);
  };
  const actions = (s: Record<string, any>) => [s.Action].flat();
  const footage = () => Object.keys(t.findResources('AWS::S3::Bucket')).find((id) => id.startsWith('Footage'))!;

  it('the web Lambda may list, abort and delete under accounts/ only', () => {
    const st = statements('WebApi');
    const list = st.find((s) => actions(s).includes('s3:ListBucket'))!;
    expect(list.Condition).toEqual({ StringLike: { 's3:prefix': ['accounts/*'] } });
    expect(st.find((s) => actions(s).includes('s3:ListBucketMultipartUploads'))!.Resource).toEqual({
      'Fn::GetAtt': [footage(), 'Arn'],
    });
    const del = st.find((s) => actions(s).includes('s3:DeleteObject'))!;
    expect(actions(del).sort()).toEqual(['s3:AbortMultipartUpload', 's3:DeleteObject']);
    expect(JSON.stringify(del.Resource)).toContain('/accounts/*');
    expect(st.flatMap(actions).some((a) => a === 's3:DeleteBucket' || a === 's3:*')).toBe(false);
  });

  it('the ingest Lambda may delete a segment that lands after its recording was deleted', () => {
    const del = statements('Ingest').find((s) => actions(s).some((a) => a.startsWith('s3:DeleteObject')))!;
    expect(JSON.stringify(del.Resource)).toContain('/accounts/*');
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

  it('login uses managed login, styled for the web client', () => {
    t.resourceCountIs('AWS::Cognito::UserPoolDomain', 1);
    t.hasResourceProperties('AWS::Cognito::UserPoolDomain', { ManagedLoginVersion: 2 });
    t.hasResourceProperties('AWS::Cognito::ManagedLoginBranding', {
      ClientId: Match.anyValue(),
      Settings: Match.objectLike({
        categories: Match.objectLike({ global: Match.objectLike({ colorSchemeMode: 'DYNAMIC' }) }),
      }),
      Assets: Match.arrayWith([Match.objectLike({ Category: 'FORM_LOGO', Extension: 'SVG' })]),
    });
  });

  it('the phone app signs in on managed login too, returning to the app', () => {
    t.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      AllowedOAuthFlows: ['code'],
      GenerateSecret: false,
      CallbackURLs: ['opensportsball://auth'],
    });
    // One style per client, or managed login shows the app an error page.
    t.resourceCountIs('AWS::Cognito::ManagedLoginBranding', 2);
    const [authorizer] = Object.values(t.findResources('AWS::ApiGatewayV2::Authorizer', { Properties: { AuthorizerType: 'JWT' } }));
    expect(authorizer!.Properties.JwtConfiguration.Audience).toHaveLength(2);
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
      authDomain: 'auth.example.com',
      authCertArn: 'arn:aws:acm:us-east-1:111111111111:certificate/auth',
    });
    d = Template.fromStack(stack);
  }, 120_000);

  it('serves the apex and www with the certificate, redirecting every other address to the apex', () => {
    d.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        Aliases: ['example.com', 'www.example.com'],
        ViewerCertificate: Match.objectLike({ AcmCertificateArn: 'arn:aws:acm:us-east-1:111111111111:certificate/test' }),
      }),
    });
    d.resourceCountIs('AWS::CloudFront::Function', 1);
    const fn = Object.values(d.findResources('AWS::CloudFront::Function'))[0];
    expect(fn.Properties.FunctionCode).toContain("if (r.headers.host.value === 'example.com') return r;");
    expect(fn.Properties.FunctionCode).toContain("'https://example.com' + r.uri");
  });

  it('login accepts the custom domain and the CloudFront address', () => {
    d.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      CallbackURLs: Match.arrayWith(['https://example.com/callback']),
    });
    const web = Object.values(d.findResources('AWS::Cognito::UserPoolClient')).find((c) =>
      c.Properties.CallbackURLs.includes('https://example.com/callback'),
    );
    expect(web!.Properties.CallbackURLs).toHaveLength(2);
  });

  it('signs in at the custom login domain, keeping the prefix domain', () => {
    d.resourceCountIs('AWS::Cognito::UserPoolDomain', 2);
    d.hasResourceProperties('AWS::Cognito::UserPoolDomain', {
      Domain: 'auth.example.com',
      CustomDomainConfig: { CertificateArn: 'arn:aws:acm:us-east-1:111111111111:certificate/auth' },
      ManagedLoginVersion: 2,
    });
    d.hasOutput('LoginDomain', { Value: 'https://auth.example.com' });
    d.hasOutput('LoginCdnDomain', {});
  });
});
