// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Everything for Phase 2: footage bucket, DynamoDB, Cognito, the HTTP API
 * and its Lambdas, and the website on CloudFront. Nothing here runs or
 * bills between games except storage and on-demand DynamoDB.
 */

import { existsSync } from 'node:fs';
import { join } from 'node:path';
import * as cdk from 'aws-cdk-lib';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as apigw from 'aws-cdk-lib/aws-apigatewayv2';
import { HttpLambdaAuthorizer, HttpLambdaResponseType, HttpUserPoolAuthorizer } from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import { HttpLambdaIntegration } from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as events from 'aws-cdk-lib/aws-events';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as s3n from 'aws-cdk-lib/aws-s3-notifications';
import type { Construct } from 'constructs';
import { loginBrandingAssets, loginBrandingSettings } from './login-branding.js';

/** Where managed login sends the phone app back to (docs/API.md). */
export const APP_LOGIN_CALLBACK = 'opensportsball://auth';

export interface OpenSportsBallStackProps extends cdk.StackProps {
  /** Repository root (contains api/, web/, shared/). */
  repoRoot: string;
  /** Cognito login domain prefix; must be globally unique. */
  authDomainPrefix: string;
  /** Custom login domain, e.g. auth.example.com. The website signs in
   *  there instead of the Cognito prefix domain. Needs authCertArn, and the
   *  parent domain must already resolve (Cognito checks). */
  authDomain?: string;
  /** ACM certificate in us-east-1 covering authDomain. */
  authCertArn?: string;
  /** Extra origins allowed to call the API and use the login, e.g.
   *  http://localhost:5173 for local web development. */
  devOrigins?: string[];
  /** Custom website domain, e.g. example.com. The site is served there and
   *  at www.<domain>, which redirects to it. Needs siteCertArn. */
  siteDomain?: string;
  /** ACM certificate in us-east-1 covering siteDomain and www.<siteDomain>. */
  siteCertArn?: string;
}

export class OpenSportsBallStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OpenSportsBallStackProps) {
    super(scope, id, props);
    const devOrigins = props.devOrigins ?? [];
    const { siteDomain, siteCertArn } = props;
    if (!siteDomain !== !siteCertArn) throw new Error('siteDomain and siteCertArn go together');
    const { authDomain, authCertArn } = props;
    if (!authDomain !== !authCertArn) throw new Error('authDomain and authCertArn go together');

    // --- Storage ------------------------------------------------------------

    const table = new dynamodb.TableV2(this, 'Table', {
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sk', type: dynamodb.AttributeType.STRING },
      timeToLiveAttribute: 'ttl',
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const footage = new s3.Bucket(this, 'Footage', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      // Raw footage is deleted after rendering in Phase 3; here only
      // abandoned multipart uploads are cleaned up.
      lifecycleRules: [{ abortIncompleteMultipartUploadAfter: cdk.Duration.days(7) }],
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    // --- Website ------------------------------------------------------------

    const site = new s3.Bucket(this, 'Site', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    const cdn = new cloudfront.Distribution(this, 'SiteCdn', {
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(site),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        functionAssociations: siteDomain
          ? [
              {
                eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
                function: new cloudfront.Function(this, 'WwwRedirect', {
                  runtime: cloudfront.FunctionRuntime.JS_2_0,
                  code: cloudfront.FunctionCode.fromInline(`function handler(event) {
  var r = event.request;
  // www and the CloudFront address both go to the one site address, so
  // links the site builds from its own address (upload permission links)
  // and sign-ins all use it.
  if (r.headers.host.value === '${siteDomain}') return r;
  var qs = Object.keys(r.querystring).map(function (k) {
    var v = r.querystring[k];
    return v.multiValue ? v.multiValue.map(function (m) { return k + '=' + m.value; }).join('&') : k + '=' + v.value;
  }).join('&');
  return { statusCode: 301, statusDescription: 'Moved Permanently',
    headers: { location: { value: 'https://${siteDomain}' + r.uri + (qs ? '?' + qs : '') } } };
}`),
                }),
              },
            ]
          : undefined,
      },
      ...(siteDomain && siteCertArn
        ? {
            domainNames: [siteDomain, `www.${siteDomain}`],
            certificate: acm.Certificate.fromCertificateArn(this, 'SiteCert', siteCertArn),
          }
        : {}),
      defaultRootObject: 'index.html',
      // Client-side routes: serve the app shell for unknown paths.
      errorResponses: [403, 404].map((httpStatus) => ({
        httpStatus,
        responseHttpStatus: 200,
        responsePagePath: '/index.html',
        ttl: cdk.Duration.seconds(0),
      })),
    });
    const cdnUrl = `https://${cdn.distributionDomainName}`;
    const siteUrl = siteDomain ? `https://${siteDomain}` : cdnUrl;
    // The CloudFront address keeps working alongside the custom domain.
    const siteOrigins = [...new Set([siteUrl, cdnUrl])];

    // --- Accounts -----------------------------------------------------------

    const users = new cognito.UserPool(this, 'Users', {
      selfSignUpEnabled: true,
      signInAliases: { email: true },
      autoVerify: { email: true },
      standardAttributes: { email: { required: true, mutable: true } },
      passwordPolicy: { minLength: 10, requireSymbols: false },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });
    // Managed login (not the classic hosted UI), styled like the site. The
    // prefix domain stays as a fallback when there's a custom one.
    const prefixLogin = users.addDomain('Login', {
      cognitoDomain: { domainPrefix: props.authDomainPrefix },
      managedLoginVersion: cognito.ManagedLoginVersion.NEWER_MANAGED_LOGIN,
    });
    const customLogin =
      authDomain && authCertArn
        ? users.addDomain('CustomLogin', {
            customDomain: {
              domainName: authDomain,
              certificate: acm.Certificate.fromCertificateArn(this, 'AuthCert', authCertArn),
            },
            managedLoginVersion: cognito.ManagedLoginVersion.NEWER_MANAGED_LOGIN,
          })
        : undefined;
    // Cognito allows one domain change at a time per pool.
    customLogin?.node.addDependency(prefixLogin);
    const loginUrl = customLogin ? `https://${authDomain}` : prefixLogin.baseUrl();
    const webClient = users.addClient('Web', {
      generateSecret: false,
      preventUserExistenceErrors: true,
      supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [...siteOrigins, ...devOrigins].map((o) => `${o}/callback`),
        logoutUrls: [...siteOrigins, ...devOrigins].map((o) => `${o}/`),
      },
      accessTokenValidity: cdk.Duration.hours(1),
      idTokenValidity: cdk.Duration.hours(1),
      refreshTokenValidity: cdk.Duration.days(30),
    });
    // The phone app signs in (or signs up) on the same managed login pages,
    // only to get a link code for itself; it keeps the device token, not
    // these tokens, so they can be short-lived.
    const appClient = users.addClient('App', {
      generateSecret: false,
      preventUserExistenceErrors: true,
      supportedIdentityProviders: [cognito.UserPoolClientIdentityProvider.COGNITO],
      oAuth: {
        flows: { authorizationCodeGrant: true },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL, cognito.OAuthScope.PROFILE],
        callbackUrls: [APP_LOGIN_CALLBACK],
        logoutUrls: [APP_LOGIN_CALLBACK],
      },
      accessTokenValidity: cdk.Duration.hours(1),
      idTokenValidity: cdk.Duration.hours(1),
      refreshTokenValidity: cdk.Duration.hours(1),
    });
    // Managed login shows an error page to a client without a style.
    for (const [id, client] of [['LoginBranding', webClient], ['AppLoginBranding', appClient]] as const) {
      new cognito.CfnManagedLoginBranding(this, id, {
        userPoolId: users.userPoolId,
        clientId: client.userPoolClientId,
        settings: loginBrandingSettings(),
        assets: loginBrandingAssets(),
      });
    }

    // --- API ----------------------------------------------------------------

    const fn = (name: string, handler: string, timeout = 29) =>
      new nodejs.NodejsFunction(this, name, {
        entry: join(props.repoRoot, 'api', 'src', 'handlers', `${handler}.ts`),
        // Bundled with api/'s own esbuild. Local bundling can still read
        // shared/ (the manifest schema), outside this root.
        projectRoot: join(props.repoRoot, 'api'),
        depsLockFilePath: join(props.repoRoot, 'api', 'package-lock.json'),
        runtime: lambda.Runtime.NODEJS_22_X,
        architecture: lambda.Architecture.ARM_64,
        memorySize: 512,
        timeout: cdk.Duration.seconds(timeout),
        environment: { TABLE_NAME: table.tableName, BUCKET_NAME: footage.bucketName },
        logGroup: new logs.LogGroup(this, `${name}Logs`, {
          retention: logs.RetentionDays.ONE_MONTH,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
        }),
        bundling: {
          // Bundle the SDK too, so behavior doesn't depend on the runtime's copy.
          externalModules: [],
          minify: true,
          sourceMap: true,
          target: 'node22',
        },
      });

    const webFn = fn('WebApi', 'web');
    const deviceFn = fn('DeviceApi', 'device');
    const authFn = fn('DeviceAuthorizer', 'authorizer', 10);
    const ingestFn = fn('Ingest', 'ingest', 60);

    table.grantReadWriteData(webFn);
    table.grantReadWriteData(deviceFn);
    table.grantReadWriteData(ingestFn);
    table.grantReadData(authFn);
    footage.grantReadWrite(deviceFn);
    // Deleting a recording or game from the website: list, abort and delete
    // what is under accounts/ (never the bucket itself).
    webFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:ListBucket'],
        resources: [footage.bucketArn],
        conditions: { StringLike: { 's3:prefix': ['accounts/*'] } },
      }),
    );
    webFn.addToRolePolicy(
      new iam.PolicyStatement({ actions: ['s3:ListBucketMultipartUploads'], resources: [footage.bucketArn] }),
    );
    webFn.addToRolePolicy(
      new iam.PolicyStatement({
        actions: ['s3:DeleteObject', 's3:AbortMultipartUpload'],
        resources: [footage.arnForObjects('accounts/*')],
      }),
    );
    // Deleting the account (DELETE /me) also deletes its sign-in.
    webFn.addEnvironment('USER_POOL_ID', users.userPoolId);
    webFn.addToRolePolicy(
      new iam.PolicyStatement({ actions: ['cognito-idp:AdminDeleteUser'], resources: [users.userPoolArn] }),
    );
    // A segment that lands after its recording was deleted is removed.
    footage.grantDelete(ingestFn, 'accounts/*');
    const defaultBus = events.EventBus.fromEventBusName(this, 'DefaultBus', 'default');
    defaultBus.grantPutEventsTo(deviceFn);
    defaultBus.grantPutEventsTo(ingestFn);

    footage.addEventNotification(s3.EventType.OBJECT_CREATED, new s3n.LambdaDestination(ingestFn), {
      prefix: 'accounts/',
      suffix: '.mp4',
    });

    const api = new apigw.HttpApi(this, 'Api', {
      corsPreflight: {
        allowOrigins: [...siteOrigins, ...devOrigins],
        allowHeaders: ['authorization', 'content-type'],
        allowMethods: [
          apigw.CorsHttpMethod.GET,
          apigw.CorsHttpMethod.POST,
          apigw.CorsHttpMethod.PUT,
          apigw.CorsHttpMethod.DELETE,
        ],
        maxAge: cdk.Duration.hours(1),
      },
    });
    // Caps cost and makes guessing link codes pointless.
    const stage = api.defaultStage!.node.defaultChild as apigw.CfnStage;
    stage.defaultRouteSettings = { throttlingBurstLimit: 50, throttlingRateLimit: 20 };

    const people = new HttpUserPoolAuthorizer('People', users, { userPoolClients: [webClient, appClient] });
    const phones = new HttpLambdaAuthorizer('Phones', authFn, {
      responseTypes: [HttpLambdaResponseType.SIMPLE],
      identitySource: ['$request.header.Authorization'],
      // No caching: unlinking a phone must take effect immediately.
      resultsCacheTtl: cdk.Duration.seconds(0),
    });
    const webIntegration = new HttpLambdaIntegration('WebIntegration', webFn);
    const deviceIntegration = new HttpLambdaIntegration('DeviceIntegration', deviceFn);

    const route = (
      method: apigw.HttpMethod,
      path: string,
      integration: HttpLambdaIntegration,
      authorizer?: apigw.IHttpRouteAuthorizer,
    ) => api.addRoutes({ path, methods: [method], integration, authorizer });

    const { GET, POST, PUT, DELETE } = apigw.HttpMethod;
    route(GET, '/me', webIntegration, people);
    route(DELETE, '/me', webIntegration, people); // deletes the account and everything in it
    route(POST, '/link-codes', webIntegration, people);
    route(GET, '/devices', webIntegration, people);
    route(DELETE, '/devices/{deviceId}', webIntegration, people);
    route(GET, '/games', webIntegration, people);
    route(GET, '/games/{gameId}', webIntegration, people);
    route(DELETE, '/games/{gameId}', webIntegration, people);
    route(DELETE, '/games/{gameId}/recordings/{recordingId}', webIntegration, people);
    route(POST, '/games/{gameId}/grant-tickets', webIntegration, people); // a link for a phone with no grant
    route(POST, '/devices/link', deviceIntegration); // the link code is the credential
    route(POST, '/devices/unlink', deviceIntegration, phones); // a phone leaves its account
    route(POST, '/games/{gameId}/grants', deviceIntegration, phones); // Main lets its Secondary upload
    route(POST, '/grant-tickets', deviceIntegration, phones); // Main stocks grants for pairings without signal
    route(POST, '/grants/redeem', deviceIntegration); // the ticket is the credential
    route(POST, '/grants/lookup', deviceIntegration); // the website's /grant page, with the ticket
    route(PUT, '/games/{gameId}/recordings/{recordingId}/manifest', deviceIntegration, phones);
    route(PUT, '/games/{gameId}/recordings/{recordingId}/report', deviceIntegration, phones);
    route(POST, '/uploads', deviceIntegration, phones);
    route(POST, '/uploads/complete', deviceIntegration, phones);

    // --- Hand-off to processing ----------------------------------------------

    // Phase 3 adds the Step Functions target. Until then, log the events so a
    // finished upload is visible in CloudWatch.
    new events.Rule(this, 'RecordingReady', {
      eventPattern: { source: ['opensportsball'], detailType: ['RecordingReady'] },
      targets: [
        new targets.CloudWatchLogGroup(
          new logs.LogGroup(this, 'RecordingReadyLog', {
            retention: logs.RetentionDays.THREE_MONTHS,
            removalPolicy: cdk.RemovalPolicy.DESTROY,
          }),
        ),
      ],
    });

    // --- Website files ------------------------------------------------------

    const webBuild = join(props.repoRoot, 'web', 'build');
    if (existsSync(join(webBuild, 'index.html'))) {
      new s3deploy.BucketDeployment(this, 'SiteFiles', {
        sources: [s3deploy.Source.asset(webBuild, { exclude: ['config.json', 'config.example.json'] })],
        destinationBucket: site,
        // Leaves the config.json written by SiteConfig in place.
        exclude: ['config.json'],
        distribution: cdn,
        distributionPaths: ['/*'],
      });
    } else {
      cdk.Annotations.of(this).addWarningV2(
        'osb:no-web-build',
        'web/build not found: the website files are not deployed. Run `npm run build` in web/ first.',
      );
    }
    const siteConfig = new s3deploy.BucketDeployment(this, 'SiteConfig', {
      sources: [
        s3deploy.Source.jsonData('config.json', {
          apiUrl: api.apiEndpoint,
          region: this.region,
          userPoolId: users.userPoolId,
          userPoolClientId: webClient.userPoolClientId,
          appClientId: appClient.userPoolClientId,
          cognitoDomain: loginUrl,
        }),
      ],
      destinationBucket: site,
      prune: false,
      cacheControl: [s3deploy.CacheControl.noCache()],
      distribution: cdn,
      distributionPaths: ['/config.json'],
    });
    siteConfig.node.addDependency(cdn);

    // --- Outputs ------------------------------------------------------------

    new cdk.CfnOutput(this, 'SiteUrl', { value: siteUrl });
    new cdk.CfnOutput(this, 'CdnDomain', { value: cdn.distributionDomainName });
    new cdk.CfnOutput(this, 'ApiUrl', { value: api.apiEndpoint });
    new cdk.CfnOutput(this, 'UserPoolId', { value: users.userPoolId });
    new cdk.CfnOutput(this, 'UserPoolClientId', { value: webClient.userPoolClientId });
    new cdk.CfnOutput(this, 'AppClientId', { value: appClient.userPoolClientId });
    new cdk.CfnOutput(this, 'LoginDomain', { value: loginUrl });
    if (customLogin) new cdk.CfnOutput(this, 'LoginCdnDomain', { value: customLogin.cloudFrontEndpoint });
    new cdk.CfnOutput(this, 'FootageBucket', { value: footage.bucketName });
    new cdk.CfnOutput(this, 'TableName', { value: table.tableName });
  }
}
