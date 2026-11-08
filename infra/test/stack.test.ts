// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import { generateKeyPairSync } from 'node:crypto';
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
      { key: 'DELETE /admin/accounts/{accountId}/games/{gameId}', auth: 'JWT' },
      { key: 'DELETE /admin/accounts/{accountId}/games/{gameId}/recordings/{recordingId}', auth: 'JWT' },
      { key: 'DELETE /devices/{deviceId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}/recordings/{recordingId}', auth: 'JWT' },
      { key: 'DELETE /me', auth: 'JWT' },
      { key: 'GET /admin/accounts', auth: 'JWT' },
      { key: 'GET /admin/accounts/{accountId}/games', auth: 'JWT' },
      { key: 'GET /devices', auth: 'JWT' },
      { key: 'GET /games', auth: 'JWT' },
      { key: 'GET /games/{gameId}', auth: 'JWT' },
      { key: 'GET /me', auth: 'JWT' },
      { key: 'POST /devices/link', auth: 'NONE' },
      { key: 'POST /devices/unlink', auth: 'CUSTOM' },
      { key: 'POST /games/{gameId}/grant-tickets', auth: 'JWT' },
      { key: 'POST /games/{gameId}/grants', auth: 'CUSTOM' },
      { key: 'POST /games/{gameId}/recordings/{recordingId}/downloads', auth: 'JWT' },
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

  it('has an admins group, and only the admin Lambda may list users', () => {
    t.hasResourceProperties('AWS::Cognito::UserPoolGroup', { GroupName: 'admins' });
    const listers = Object.entries(t.findResources('AWS::IAM::Policy')).filter(([, p]) =>
      JSON.stringify(p.Properties.PolicyDocument).includes('cognito-idp:ListUsers'),
    );
    expect(listers.map(([id]) => id)).toEqual([expect.stringMatching(/^AdminApi/)]);
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
    expect(fns).toHaveLength(5);
    for (const f of fns) {
      expect(f.Properties.Runtime).toBe('nodejs22.x');
      expect(f.Properties.Architectures).toEqual(['arm64']);
    }
  });
});

describe('storage', () => {
  it('footage bucket is private, encrypted, kept on stack delete, and cleans up abandoned and old uploads', () => {
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
          Rules: [
            Match.objectLike({ AbortIncompleteMultipartUpload: { DaysAfterInitiation: 7 } }),
            // Only the phones' uploads: bench/ and data/ are never expired.
            { Id: 'ExpireUploads', Prefix: 'accounts/', ExpirationInDays: 180, Status: 'Enabled' },
          ],
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

  it('sends security headers with every page, and no site may frame it', () => {
    const policies = Object.entries(t.findResources('AWS::CloudFront::ResponseHeadersPolicy'));
    expect(policies).toHaveLength(1);
    const [id, policy] = policies[0]!;
    t.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: Match.objectLike({
        DefaultCacheBehavior: Match.objectLike({ ResponseHeadersPolicyId: { Ref: id } }),
      }),
    });
    const sec = policy.Properties.ResponseHeadersPolicyConfig.SecurityHeadersConfig;
    expect(sec.FrameOptions).toEqual({ FrameOption: 'DENY', Override: true });
    expect(sec.ContentTypeOptions).toEqual({ Override: true });
    expect(sec.StrictTransportSecurity.AccessControlMaxAgeSec).toBe(365 * 24 * 3600);
    const csp = JSON.stringify(sec.ContentSecurityPolicy.ContentSecurityPolicy);
    expect(csp).toContain("frame-ancestors 'none'");
    expect(csp).toContain("object-src 'none'");
    expect(csp).toContain('https://osb-test.auth.');
    expect(csp).toContain('https://*.execute-api.');
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

  it('lets the site reach the custom login domain', () => {
    const policy = Object.values(d.findResources('AWS::CloudFront::ResponseHeadersPolicy'))[0]!;
    const csp = JSON.stringify(policy.Properties.ResponseHeadersPolicyConfig.SecurityHeadersConfig.ContentSecurityPolicy);
    expect(csp).toContain('https://auth.example.com');
    expect(csp).not.toContain('osb-test.auth.');
  });
});

describe('footage downloads', () => {
  let f: Template;
  const publicKey = generateKeyPairSync('rsa', { modulusLength: 2048 })
    .publicKey.export({ type: 'spki', format: 'pem' })
    .toString()
    .trim();
  beforeAll(() => {
    const app = new cdk.App({ context: { '@aws-cdk/customresources:installLatestAwsSdkDefault': false } });
    const stack = new OpenSportsBallStack(app, 'TestFootage', {
      repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), '..', '..'),
      authDomainPrefix: 'osb-test',
      footageSigningPublicKey: publicKey,
    });
    f = Template.fromStack(stack);
  }, 120_000);

  const footageCdn = () =>
    Object.values(f.findResources('AWS::CloudFront::Distribution')).find((d) =>
      String(d.Properties.DistributionConfig.Comment).includes('footage'),
    )!;

  it('has no footage distribution without a signing key', () => {
    t.resourceCountIs('AWS::CloudFront::Distribution', 1);
    t.resourceCountIs('AWS::CloudFront::PublicKey', 0);
    expect(Object.keys(t.toJSON().Outputs)).not.toContain('FootageCdnDomain');
  });

  it('serves footage only with a URL signed by the deployment key, over HTTPS, uncached', () => {
    f.resourceCountIs('AWS::CloudFront::Distribution', 2);
    f.hasResourceProperties('AWS::CloudFront::PublicKey', {
      PublicKeyConfig: Match.objectLike({ EncodedKey: publicKey }),
    });
    const [keyGroup] = Object.keys(f.findResources('AWS::CloudFront::KeyGroup'));
    const b = footageCdn().Properties.DistributionConfig.DefaultCacheBehavior;
    expect(b.TrustedKeyGroups).toEqual([{ Ref: keyGroup }]);
    expect(b.ViewerProtocolPolicy).toBe('https-only');
    expect(b.AllowedMethods).toEqual(['GET', 'HEAD']);
    // AWS's managed CachingDisabled policy.
    expect(b.CachePolicyId).toBe('4135ea2d-6df8-44a3-9df3-4b5a84be39ad');
    expect(footageCdn().Properties.DistributionConfig.PriceClass).toBe('PriceClass_100');
    f.hasOutput('FootageCdnDomain', {});
  });

  it('reads the footage bucket through origin access control, read-only', () => {
    const footage = Object.keys(f.findResources('AWS::S3::Bucket')).find((id) => id.startsWith('Footage'))!;
    const policy = Object.values(f.findResources('AWS::S3::BucketPolicy')).find(
      (p) => p.Properties.Bucket.Ref === footage,
    )!;
    const cf = (policy.Properties.PolicyDocument.Statement as Array<Record<string, any>>).filter(
      (s) => s.Principal?.Service === 'cloudfront.amazonaws.com',
    );
    expect(cf.map((s) => s.Action)).toEqual(['s3:GetObject']);
  });

  it('the web Lambda can sign: it knows the distribution and key, and may read only its key parameter', () => {
    const web = Object.values(f.findResources('AWS::Lambda::Function')).find(
      (fn) => fn.Properties.Environment?.Variables?.FOOTAGE_CDN_DOMAIN,
    )!;
    const vars = web.Properties.Environment.Variables;
    expect(vars.FOOTAGE_SIGNING_KEY_PARAM).toBe('/TestFootage/footage-signing-key');
    expect(vars.FOOTAGE_KEY_PAIR_ID).toEqual({ Ref: expect.stringMatching(/^FootageSigningKey/) });
    const readers = Object.values(f.findResources('AWS::IAM::Policy')).flatMap((p) =>
      (p.Properties.PolicyDocument.Statement as Array<Record<string, any>>).filter((s) =>
        [s.Action].flat().includes('ssm:GetParameter'),
      ),
    );
    expect(readers).toHaveLength(1);
    expect(JSON.stringify(readers[0]!.Resource)).toContain(':parameter/TestFootage/footage-signing-key');
  });
});
