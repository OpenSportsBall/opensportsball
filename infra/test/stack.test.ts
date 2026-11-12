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
    const byKey = (a: { key: string }, b: { key: string }) => a.key.localeCompare(b.key);
    expect(routes().sort(byKey)).toEqual([
      { key: 'DELETE /admin/accounts/{accountId}/games/{gameId}', auth: 'JWT' },
      { key: 'DELETE /admin/accounts/{accountId}/games/{gameId}/recordings/{recordingId}', auth: 'JWT' },
      { key: 'DELETE /devices/{deviceId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}/recordings/{recordingId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}/recordings/{recordingId}/footage-links/{linkId}', auth: 'JWT' },
      { key: 'DELETE /games/{gameId}/recordings/{recordingId}/jobs/{jobId}', auth: 'JWT' },
      { key: 'DELETE /me', auth: 'JWT' },
      { key: 'GET /admin/accounts', auth: 'JWT' },
      { key: 'DELETE /contributions/{contributionId}', auth: 'JWT' },
      { key: 'GET /admin/accounts/{accountId}/games', auth: 'JWT' },
      { key: 'GET /contributions', auth: 'JWT' },
      { key: 'GET /devices', auth: 'JWT' },
      { key: 'GET /games', auth: 'JWT' },
      { key: 'GET /games/{gameId}', auth: 'JWT' },
      { key: 'GET /games/{gameId}/recordings/{recordingId}/footage-links', auth: 'JWT' },
      { key: 'GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}', auth: 'JWT' },
      { key: 'GET /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/questions', auth: 'JWT' },
      { key: 'GET /me', auth: 'JWT' },
      { key: 'POST /contributions', auth: 'JWT' },
      { key: 'POST /contributions/{contributionId}/complete', auth: 'JWT' },
      { key: 'POST /devices/link', auth: 'NONE' },
      { key: 'POST /devices/unlink', auth: 'CUSTOM' },
      { key: 'POST /footage-links/lookup', auth: 'NONE' },
      { key: 'POST /games/{gameId}/grant-tickets', auth: 'JWT' },
      { key: 'POST /games/{gameId}/grants', auth: 'CUSTOM' },
      { key: 'POST /games/{gameId}/recordings/{recordingId}/downloads', auth: 'JWT' },
      { key: 'POST /games/{gameId}/recordings/{recordingId}/footage-links', auth: 'JWT' },
      { key: 'POST /games/{gameId}/recordings/{recordingId}/jobs', auth: 'JWT' },
      { key: 'POST /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/downloads', auth: 'JWT' },
      { key: 'POST /grant-tickets', auth: 'CUSTOM' },
      { key: 'POST /grants/lookup', auth: 'NONE' },
      { key: 'POST /grants/redeem', auth: 'NONE' },
      { key: 'POST /link-codes', auth: 'JWT' },
      { key: 'POST /uploads', auth: 'CUSTOM' },
      { key: 'POST /uploads/complete', auth: 'CUSTOM' },
      { key: 'PUT /admin/accounts/{accountId}/cloud-processing', auth: 'JWT' },
      { key: 'PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/answers', auth: 'JWT' },
      { key: 'PUT /games/{gameId}/recordings/{recordingId}/jobs/{jobId}/status', auth: 'JWT' },
      { key: 'PUT /games/{gameId}/recordings/{recordingId}/manifest', auth: 'CUSTOM' },
      { key: 'PUT /games/{gameId}/recordings/{recordingId}/report', auth: 'CUSTOM' },
    ].sort(byKey));
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
    expect(fns).toHaveLength(6);
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
            // Only the phones' uploads and what processing made from them:
            // bench/, data/ and models/ are never expired.
            { Id: 'ExpireUploads', Prefix: 'accounts/', ExpirationInDays: 180, Status: 'Enabled' },
            { Id: 'ExpireOutputs', Prefix: 'outputs/', ExpirationInDays: 180, Status: 'Enabled' },
            { Id: 'ExpireWork', Prefix: 'work/', ExpirationInDays: 7, Status: 'Enabled' },
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

  it('the web Lambda may list, abort and delete under accounts/ and what processing made from it, only', () => {
    const st = statements('WebApi');
    const list = st.find((s) => actions(s).includes('s3:ListBucket'))!;
    expect(list.Condition).toEqual({ StringLike: { 's3:prefix': ['accounts/*', 'outputs/*', 'work/*'] } });
    expect(st.find((s) => actions(s).includes('s3:ListBucketMultipartUploads'))!.Resource).toEqual({
      'Fn::GetAtt': [footage(), 'Arn'],
    });
    const del = st.find((s) => actions(s).includes('s3:DeleteObject'))!;
    expect(actions(del).sort()).toEqual(['s3:AbortMultipartUpload', 's3:DeleteObject']);
    for (const p of ['/accounts/*', '/outputs/*', '/work/*']) expect(JSON.stringify(del.Resource)).toContain(p);
    expect(del.Resource).toHaveLength(3);
    expect(st.flatMap(actions).some((a) => a === 's3:DeleteBucket' || a === 's3:*')).toBe(false);
  });

  it('contributions have their own private bucket, kept on stack delete and not expired with footage', () => {
    const [id, bucket] = Object.entries(t.findResources('AWS::S3::Bucket')).find(([k]) => k.startsWith('Contributions'))!;
    expect(bucket.DeletionPolicy).toBe('Retain');
    expect(bucket.Properties.PublicAccessBlockConfiguration).toEqual({
      BlockPublicAcls: true,
      BlockPublicPolicy: true,
      IgnorePublicAcls: true,
      RestrictPublicBuckets: true,
    });
    // Without contributionRetentionDays nothing expires: kept until withdrawn.
    expect(bucket.Properties.LifecycleConfiguration.Rules).toEqual([
      expect.objectContaining({ AbortIncompleteMultipartUpload: { DaysAfterInitiation: 7 } }),
    ]);
    // Only the web Lambda may write and delete there, under contributions/.
    const rw = statements('WebApi').find((s) => JSON.stringify(s.Resource).includes(id) && actions(s).includes('s3:PutObject'))!;
    expect(JSON.stringify(rw.Resource)).toContain('/contributions/*');
    for (const fn of ['DeviceApi', 'Ingest', 'AdminApi']) {
      expect(JSON.stringify(statements(fn)).includes(id), fn).toBe(false);
    }
    const web = Object.values(t.findResources('AWS::Lambda::Function')).find((f) =>
      JSON.stringify(f.Properties.Environment ?? {}).includes('CONTRIBUTIONS_BUCKET_NAME'),
    )!;
    expect(web.Properties.Environment.Variables.CONTRIBUTIONS_BUCKET_NAME).toEqual({ Ref: id });
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
    t.resourceCountIs('AWS::Cognito::ManagedLoginBranding', 3);
    const [authorizer] = Object.values(t.findResources('AWS::ApiGatewayV2::Authorizer', { Properties: { AuthorizerType: 'JWT' } }));
    expect(authorizer!.Properties.JwtConfiguration.Audience).toHaveLength(3);
  });

  it('the desktop app signs in on managed login and keeps a 30-day refresh token', () => {
    t.hasResourceProperties('AWS::Cognito::UserPoolClient', {
      AllowedOAuthFlows: ['code'],
      GenerateSecret: false,
      // The Mac app's own scheme, and the `osb` command's listener on this computer.
      CallbackURLs: [
        'opensportsball://desktop-auth',
        'http://localhost:47161/callback',
        'http://localhost:47162/callback',
        'http://localhost:47163/callback',
      ],
      RefreshTokenValidity: 43200,
      TokenValidityUnits: Match.objectLike({ RefreshToken: 'minutes' }),
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

  it('tells browsers to save footage, so a link on the website downloads it', () => {
    const b = footageCdn().Properties.DistributionConfig.DefaultCacheBehavior;
    const policy = f.findResources('AWS::CloudFront::ResponseHeadersPolicy')[b.ResponseHeadersPolicyId.Ref]!;
    expect(policy.Properties.ResponseHeadersPolicyConfig.CustomHeadersConfig.Items).toEqual([
      { Header: 'Content-Disposition', Value: 'attachment', Override: true },
    ]);
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

describe('cloud processing', () => {
  const statements = (t: Template, rolePrefix: string) => {
    const roles = Object.keys(t.findResources('AWS::IAM::Role')).filter((id) => id.startsWith(rolePrefix));
    return Object.values(t.findResources('AWS::IAM::Policy'))
      .filter((p) => p.Properties.Roles.some((r: { Ref: string }) => roles.includes(r.Ref)))
      .flatMap((p) => p.Properties.PolicyDocument.Statement as Array<Record<string, any>>);
  };
  const actions = (s: Record<string, any>) => [s.Action].flat() as string[];
  const defs = (t: Template) =>
    Object.fromEntries(
      Object.entries(t.findResources('AWS::Batch::JobDefinition')).map(([id, d]) => [id.replace(/^Processing|[0-9A-F]{8}$/g, ''), d.Properties]),
    );

  let gpu: Template;
  beforeAll(() => {
    const app = new cdk.App({ context: { '@aws-cdk/customresources:installLatestAwsSdkDefault': false } });
    const stack = new OpenSportsBallStack(app, 'TestGpu', {
      repoRoot: resolve(dirname(fileURLToPath(import.meta.url)), '..', '..'),
      authDomainPrefix: 'osb-test',
      engineImageTag: 'v1',
      engineCompute: 'gpu',
      emailFrom: 'OpenSportsBall <no-reply@example.com>',
    });
    gpu = Template.fromStack(stack);
  }, 120_000);

  it('costs nothing idle: no NAT gateway, and both compute environments start at zero', () => {
    t.resourceCountIs('AWS::EC2::NatGateway', 0);
    t.hasResourceProperties('AWS::EC2::VPCEndpoint', { VpcEndpointType: 'Gateway' });
    t.hasResourceProperties('AWS::Batch::ComputeEnvironment', {
      Type: 'managed',
      ComputeResources: Match.objectLike({
        Type: 'SPOT',
        AllocationStrategy: 'SPOT_PRICE_CAPACITY_OPTIMIZED',
        MinvCpus: 0,
        MaxvCpus: 8,
        InstanceTypes: ['g5.xlarge', 'g6.xlarge'],
        Ec2Configuration: [{ ImageType: 'ECS_AL2023_NVIDIA' }],
      }),
    });
    t.hasResourceProperties('AWS::Batch::ComputeEnvironment', {
      ComputeResources: Match.objectLike({ Type: 'FARGATE', MaxvCpus: 8 }),
    });
  });

  it('accepts no inbound connections', () => {
    const groups = Object.values(t.findResources('AWS::EC2::SecurityGroup'));
    expect(groups).toHaveLength(1);
    expect(groups[0]!.Properties.SecurityGroupIngress).toBeUndefined();
    t.resourceCountIs('AWS::EC2::SecurityGroupIngress', 0);
  });

  it('gives the GPU instance an encrypted scratch disk', () => {
    t.hasResourceProperties('AWS::EC2::LaunchTemplate', {
      LaunchTemplateData: Match.objectLike({
        BlockDeviceMappings: [
          { DeviceName: '/dev/xvda', Ebs: { VolumeSize: 200, VolumeType: 'gp3', Encrypted: true, DeleteOnTermination: true } },
        ],
        MetadataOptions: Match.objectLike({ HttpTokens: 'required' }),
      }),
    });
  });

  it('runs the stub on Fargate by default, with a timeout per command', () => {
    const d = defs(t);
    expect(Object.keys(d).sort()).toEqual(['Prepare', 'Refit', 'Run']);
    for (const [name, seconds] of [['Prepare', 3600], ['Run', 43_200], ['Refit', 900]] as const) {
      expect(d[name].PlatformCapabilities, name).toEqual(['FARGATE']);
      expect(d[name].Timeout).toEqual({ AttemptDurationSeconds: seconds });
      expect(d[name].ContainerProperties.Command).toEqual([name.toLowerCase()]);
      expect(d[name].ContainerProperties.NetworkConfiguration).toEqual({ AssignPublicIp: 'ENABLED' });
      expect(JSON.stringify(d[name].ContainerProperties.Image)).toContain(':stub');
    }
  });

  it('runs prepare and run on the GPU when asked, retrying only a reclaimed Spot instance', () => {
    const d = defs(gpu);
    for (const name of ['Prepare', 'Run']) {
      expect(d[name].PlatformCapabilities, name).toEqual(['EC2']);
      expect(d[name].ContainerProperties.ResourceRequirements).toEqual(
        expect.arrayContaining([{ Type: 'GPU', Value: '1' }, { Type: 'VCPU', Value: '4' }]),
      );
      expect(d[name].RetryStrategy.Attempts).toBe(5);
      expect(d[name].RetryStrategy.EvaluateOnExit).toEqual([
        { Action: 'RETRY', OnStatusReason: 'Host EC2*' },
        { Action: 'EXIT', OnReason: '*' },
      ]);
      expect(JSON.stringify(d[name].ContainerProperties.Image)).toContain(':v1');
    }
    expect(d.Refit.PlatformCapabilities).toEqual(['FARGATE']);
    // Prepare and run go to the GPU queue, refits to the CPU queue.
    for (const name of ['Prepare', 'Run']) {
      expect(d[name].ContainerProperties.Environment).toContainEqual({ Name: 'OSB_REQUIRE_GPU', Value: '1' });
    }
    expect(d.Refit.ContainerProperties.Environment).not.toContainEqual({ Name: 'OSB_REQUIRE_GPU', Value: '1' });
    expect(d.Refit.ContainerProperties.EphemeralStorage).toEqual({ SizeInGiB: 100 });
    const web = Object.values(gpu.findResources('AWS::Lambda::Function')).find((f) => f.Properties.Environment?.Variables?.BATCH_JOBS)!;
    const jobs = JSON.stringify(web.Properties.Environment.Variables.BATCH_JOBS);
    expect(jobs).toMatch(/prepare.*GpuQueue.*run.*GpuQueue.*refit.*CpuQueue/);
  });

  it('fails a job that waits too long for a machine instead of leaving it queued', () => {
    const queues = Object.values(t.findResources('AWS::Batch::JobQueue'));
    const limited = queues.find((q) => q.Properties.JobStateTimeLimitActions)!;
    expect(limited.Properties.JobStateTimeLimitActions.map((a: any) => [a.Reason, a.MaxTimeSeconds, a.Action])).toEqual([
      ['MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT', 3600, 'CANCEL'],
      ['MISCONFIGURATION:COMPUTE_ENVIRONMENT_MAX_RESOURCE', 43_200, 'CANCEL'],
      ['CAPACITY:INSUFFICIENT_INSTANCE_CAPACITY', 43_200, 'CANCEL'],
    ]);
  });

  it('the engine container reads footage and models, writes outputs and work, and touches only job records', () => {
    const st = statements(t, 'ProcessingJobRole');
    const read = st.find((s) => actions(s).length === 1 && actions(s)[0] === 's3:GetObject')!;
    expect(JSON.stringify(read.Resource)).toMatch(/\/accounts\/\*.*\/models\/\*/);
    const write = st.find((s) => actions(s).includes('s3:PutObject'))!;
    expect(JSON.stringify(write.Resource)).toMatch(/\/outputs\/\*.*\/work\/\*/);
    expect(JSON.stringify(write.Resource)).not.toContain('/accounts/');
    const table = st.find((s) => actions(s).some((a) => a.startsWith('dynamodb:')))!;
    expect(actions(table).sort()).toEqual(['dynamodb:GetItem', 'dynamodb:UpdateItem']);
    expect(table.Condition).toEqual({ 'ForAllValues:StringLike': { 'dynamodb:LeadingKeys': ['JOB#*'] } });
  });

  it('only the web and job events Lambdas may start jobs; the four that can end one may stop it', () => {
    const can = (action: string) =>
      Object.entries(t.findResources('AWS::IAM::Policy'))
        .filter(([, p]) => (p.Properties.PolicyDocument.Statement as any[]).some((s) => actions(s).includes(action)))
        .map(([id]) => id.replace(/ServiceRoleDefaultPolicy.*$/, ''))
        .sort();
    expect(can('batch:SubmitJob')).toEqual(['JobEvents', 'WebApi']);
    expect(can('batch:TerminateJob')).toEqual(['AdminApi', 'DeviceApi', 'Ingest', 'WebApi']);
  });

  it('Batch state changes on our queues reach the job events Lambda', () => {
    t.hasResourceProperties('AWS::Events::Rule', {
      EventPattern: {
        source: ['aws.batch'],
        'detail-type': ['Batch Job State Change'],
        detail: { jobQueue: Match.anyValue(), status: ['RUNNING', 'SUCCEEDED', 'FAILED'] },
      },
      Targets: [Match.objectLike({ Arn: { 'Fn::GetAtt': [Match.stringLikeRegexp('^JobEvents'), 'Arn'] } })],
    });
  });

  it('sends emails only when a sender is set', () => {
    const env = (x: Template) =>
      Object.values(x.findResources('AWS::Lambda::Function')).find((f) => f.Properties.Environment?.Variables?.SITE_URL)!
        .Properties.Environment.Variables;
    expect(env(t).EMAIL_FROM).toBeUndefined();
    expect(statements(t, 'JobEventsServiceRole').flatMap(actions)).not.toContain('ses:SendEmail');
    expect(env(gpu).EMAIL_FROM).toBe('OpenSportsBall <no-reply@example.com>');
    expect(statements(gpu, 'JobEventsServiceRole').flatMap(actions)).toContain('ses:SendEmail');
  });

  it('has a repository for the engine image', () => {
    t.resourceCountIs('AWS::ECR::Repository', 1);
    t.hasOutput('EngineRepositoryUri', {});
  });
});
