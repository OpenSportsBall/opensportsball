// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

import { randomUUID, createHash } from 'node:crypto';
import {
  CreateTableCommand,
  DeleteTableCommand,
  DynamoDBClient,
  ResourceNotFoundException,
} from '@aws-sdk/client-dynamodb';
import { CreateBucketCommand, DeleteBucketCommand, DeleteObjectsCommand, ListObjectsV2Command, S3Client } from '@aws-sdk/client-s3';
import { EventBridgeClient, PutRuleCommand, PutTargetsCommand } from '@aws-sdk/client-eventbridge';
import { CreateQueueCommand, GetQueueAttributesCommand, ReceiveMessageCommand, SQSClient } from '@aws-sdk/client-sqs';
import type { Result } from '../src/lib/http.js';
import { handler as web } from '../src/handlers/web.js';
import { handler as device } from '../src/handlers/device.js';
import { handler as authorizer } from '../src/handlers/authorizer.js';

const dynamo = new DynamoDBClient({});
const s3 = new S3Client({ forcePathStyle: true });
const sqs = new SQSClient({});
const eb = new EventBridgeClient({});

let queueUrl = '';

/** Fresh table, bucket, and an SQS queue that receives RecordingReady. */
export async function resetAws() {
  const table = process.env.TABLE_NAME!;
  const bucket = process.env.BUCKET_NAME!;
  try {
    await dynamo.send(new DeleteTableCommand({ TableName: table }));
  } catch (e) {
    if (!(e instanceof ResourceNotFoundException)) throw e;
  }
  await dynamo.send(
    new CreateTableCommand({
      TableName: table,
      BillingMode: 'PAY_PER_REQUEST',
      AttributeDefinitions: [
        { AttributeName: 'pk', AttributeType: 'S' },
        { AttributeName: 'sk', AttributeType: 'S' },
      ],
      KeySchema: [
        { AttributeName: 'pk', KeyType: 'HASH' },
        { AttributeName: 'sk', KeyType: 'RANGE' },
      ],
    }),
  );
  try {
    const listed = await s3.send(new ListObjectsV2Command({ Bucket: bucket }));
    if (listed.Contents?.length) {
      await s3.send(
        new DeleteObjectsCommand({ Bucket: bucket, Delete: { Objects: listed.Contents.map((o) => ({ Key: o.Key! })) } }),
      );
    }
    await s3.send(new DeleteBucketCommand({ Bucket: bucket }));
  } catch {
    // didn't exist
  }
  await s3.send(new CreateBucketCommand({ Bucket: bucket }));

  const q = await sqs.send(new CreateQueueCommand({ QueueName: `ready-${randomUUID()}` }));
  queueUrl = q.QueueUrl!;
  const arn = (
    await sqs.send(new GetQueueAttributesCommand({ QueueUrl: queueUrl, AttributeNames: ['QueueArn'] }))
  ).Attributes!.QueueArn!;
  const rule = `ready-${randomUUID()}`;
  await eb.send(
    new PutRuleCommand({
      Name: rule,
      EventPattern: JSON.stringify({ source: ['sportsballvideo'], 'detail-type': ['RecordingReady'] }),
    }),
  );
  await eb.send(new PutTargetsCommand({ Rule: rule, Targets: [{ Id: 'q', Arn: arn }] }));
}

export async function readyEvents(): Promise<Array<Record<string, string>>> {
  const r = await sqs.send(new ReceiveMessageCommand({ QueueUrl: queueUrl, MaxNumberOfMessages: 10 }));
  return (r.Messages ?? []).map((m) => JSON.parse(m.Body!).detail);
}

export interface Res {
  status: number;
  body: any;
}

const toRes = (r: Result): Res => ({ status: r.statusCode ?? 200, body: r.body ? JSON.parse(r.body) : undefined });

const API_DOMAIN = 'abc123.execute-api.us-east-1.amazonaws.com';

export async function callWeb(
  account: string,
  routeKey: string,
  opts: { path?: Record<string, string>; body?: unknown; email?: string } = {},
): Promise<Res> {
  const event = {
    routeKey,
    pathParameters: opts.path,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    isBase64Encoded: false,
    requestContext: {
      domainName: API_DOMAIN,
      authorizer: { jwt: { claims: { sub: account, email: opts.email ?? `${account}@example.com` }, scopes: [] } },
    },
  };
  return toRes(await web(event as any));
}

/** Calls a phone route the way API Gateway would: the authorizer runs
 *  first and its context is passed on. */
export async function callDevice(
  token: string | null,
  routeKey: string,
  opts: { path?: Record<string, string>; body?: unknown; rawBody?: string } = {},
): Promise<Res> {
  let lambda: unknown;
  if (routeKey !== 'POST /devices/link') {
    const auth = await authorizer({ headers: { authorization: `Bearer ${token}` } } as any);
    if (!auth.isAuthorized) return { status: 401, body: { error: 'unauthorized' } };
    lambda = auth.context;
  }
  const event = {
    routeKey,
    pathParameters: opts.path,
    body: opts.rawBody ?? (opts.body === undefined ? undefined : JSON.stringify(opts.body)),
    isBase64Encoded: false,
    requestContext: { domainName: API_DOMAIN, authorizer: lambda ? { lambda } : undefined },
  };
  return toRes(await device(event as any));
}

/** Links a new phone to [account]; returns its id and token. */
export async function linkPhone(account: string, model = 'Pixel 9') {
  const code = await callWeb(account, 'POST /link-codes');
  const deviceId = randomUUID();
  const linked = await callDevice(null, 'POST /devices/link', {
    body: { code: code.body.code, deviceId, platform: 'android', model },
  });
  if (linked.status !== 200) throw new Error(`link failed: ${JSON.stringify(linked.body)}`);
  return { deviceId, token: linked.body.deviceToken as string, model };
}

export const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

export interface Phone {
  deviceId: string;
  token: string;
  model: string;
}

/** A manifest for [main] (+ optional [secondary]) with the given file sizes. */
export function manifest(
  gameId: string,
  recordingId: string,
  main: Phone,
  mainFiles: Buffer[],
  secondary?: Phone,
  secondaryFiles: Buffer[] = [],
) {
  const dev = (p: Phone, role: string, files: Buffer[]) => ({
    deviceId: p.deviceId,
    role,
    position: 'unknown',
    platform: 'android',
    model: p.model,
    appVersion: '0.1.0',
    video: { width: 3840, height: 2160, nominalFps: 30, codec: 'hevc', bitrateBps: 35000000, lens: 'ultrawide', stabilization: false },
    segments: files.map((f, i) => ({
      index: i,
      objectKey: `${p.deviceId}/${fileName(p, i)}`,
      bytes: f.length,
      sha256: sha(f),
      startedAtDeviceMs: 1_760_000_000_000 + i * 300_000,
      durationMs: 300_000,
    })),
  });
  return {
    schemaVersion: 1,
    gameId,
    sessionId: recordingId,
    createdAt: new Date().toISOString(),
    devices: [dev(main, 'main', mainFiles), ...(secondary ? [dev(secondary, 'secondary', secondaryFiles)] : [])],
    ...(secondary ? { clockSync: { secondaryOffsetMs: 12.5, medianRttMs: 40, samples: 20 } } : {}),
  };
}

export const fileName = (p: Phone, i: number) => `${p.deviceId}_${String(i).padStart(3, '0')}.mp4`;

/** Uploads [data] as file [index] of [phone] through the multipart API,
 *  PUTting parts straight to the presigned URLs. [stopAfterParts] simulates
 *  the phone losing connection partway. */
export async function uploadFile(
  phone: Phone,
  gameId: string,
  recordingId: string,
  index: number,
  data: Buffer,
  stopAfterParts?: number,
): Promise<Res> {
  const name = fileName(phone, index);
  const start = await callDevice(phone.token, 'POST /uploads', {
    body: { gameId, recordingId, fileName: name, bytes: data.length, sha256: sha(data) },
  });
  if (start.status !== 200 || start.body.alreadyUploaded) return start;
  const { uploadId, partSizeBytes, parts, completedParts } = start.body;
  const etags = new Map<number, string>(completedParts.map((p: any) => [p.partNumber, p.etag]));
  let sent = 0;
  for (const p of parts) {
    if (stopAfterParts !== undefined && sent >= stopAfterParts) return { status: 0, body: { stopped: true } };
    const chunk = data.subarray((p.partNumber - 1) * partSizeBytes, p.partNumber * partSizeBytes);
    const r = await fetch(p.url, { method: 'PUT', body: new Uint8Array(chunk) });
    if (!r.ok) throw new Error(`part PUT failed ${r.status}: ${await r.text()}`);
    etags.set(p.partNumber, r.headers.get('etag')!);
    sent++;
  }
  return callDevice(phone.token, 'POST /uploads/complete', {
    body: {
      gameId,
      recordingId,
      fileName: name,
      uploadId,
      parts: [...etags.entries()].sort(([a], [b]) => a - b).map(([partNumber, etag]) => ({ partNumber, etag })),
    },
  });
}
