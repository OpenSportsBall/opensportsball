// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Cloud processing (docs/CLOUD-PROCESSING-PLAN.md): AWS Batch running the
 * engine's container on a Spot GPU instance, and on Fargate for the short
 * CPU work. Nothing here runs between games: both compute environments
 * scale to zero, and the network has no NAT gateway.
 *
 * This stack names the engine's image and reads the files it writes; the
 * engine itself lives in the opensportsball-processing repository
 * (docs/LICENSING.md). What the container is given and must leave behind
 * is in docs/API.md, "The engine's container".
 */

import * as cdk from 'aws-cdk-lib';
import * as batch from 'aws-cdk-lib/aws-batch';
import type * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import type * as s3 from 'aws-cdk-lib/aws-s3';
import { Construct } from 'constructs';

/** Where the long commands (prepare, run) run. `cpu` is for the stub
 *  engine, which needs no GPU; the real engine needs `gpu`. */
export type EngineCompute = 'cpu' | 'gpu';

export interface ProcessingProps {
  footage: s3.IBucket;
  table: dynamodb.ITableV2;
  /** Tag of the engine image in this stack's repository. */
  engineImageTag: string;
  engineCompute: EngineCompute;
}

/** The GPU quota this is sized for: 8 vCPUs of G instances, so two games
 *  at once. */
export const GPU_MAX_VCPUS = 8;
export const GPU_INSTANCE_TYPES = ['g5.xlarge', 'g6.xlarge'];
/** A game is 40-50 GB of footage in and ~22 GB out, plus the pieces. */
export const SCRATCH_GB = 200;

export type EngineCommand = 'prepare' | 'run' | 'refit';

export class Processing extends Construct {
  /** The engine's image is pushed here (infra/README.md, "Cloud processing"). */
  readonly repository: ecr.Repository;
  /** For the API's BATCH_JOBS: where each command is submitted. */
  readonly jobs: Record<EngineCommand, { queue: string; definition: string }>;
  readonly queues: batch.JobQueue[];
  private readonly definitions: batch.EcsJobDefinition[];

  constructor(scope: Construct, id: string, props: ProcessingProps) {
    super(scope, id);
    const { footage, table } = props;

    // Public subnets only: a NAT gateway would bill all month for a few
    // hours of use. Instances and tasks get a public address, accept no
    // inbound connections, and reach S3 through the gateway endpoint
    // (free, and footage never leaves the region).
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 4,
      natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
      gatewayEndpoints: { S3: { service: ec2.GatewayVpcEndpointAwsService.S3 } },
    });
    const securityGroup = new ec2.SecurityGroup(this, 'Engine', {
      vpc,
      description: 'OpenSportsBall processing: outbound only',
      allowAllOutbound: true,
    });
    const network = { vpc, vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC }, securityGroups: [securityGroup] };

    this.repository = new ecr.Repository(this, 'Image', {
      imageScanOnPush: true,
      lifecycleRules: [{ description: 'Keep the last 10 engine images', maxImageCount: 10 }],
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      emptyOnDelete: true,
    });
    const image = ecs.ContainerImage.fromEcrRepository(this.repository, props.engineImageTag);

    // --- What the container may touch -------------------------------------------

    // Batch gives every job the same role, so it can read any account's
    // footage; it cannot read an account's table items (devices, tokens,
    // grants), only job records, which live under their own partition key.
    const jobRole = new iam.Role(this, 'JobRole', {
      assumedBy: new iam.ServicePrincipal('ecs-tasks.amazonaws.com'),
      description: 'OpenSportsBall engine container',
    });
    jobRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:GetObject'],
        resources: [footage.arnForObjects('accounts/*'), footage.arnForObjects('models/*')],
      }),
    );
    jobRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:GetObject', 's3:PutObject', 's3:DeleteObject', 's3:AbortMultipartUpload'],
        resources: [footage.arnForObjects('outputs/*'), footage.arnForObjects('work/*')],
      }),
    );
    jobRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['s3:ListBucket'],
        resources: [footage.bucketArn],
        conditions: { StringLike: { 's3:prefix': ['accounts/*', 'models/*', 'outputs/*', 'work/*'] } },
      }),
    );
    jobRole.addToPolicy(
      new iam.PolicyStatement({
        actions: ['dynamodb:GetItem', 'dynamodb:UpdateItem'],
        resources: [table.tableArn],
        conditions: { 'ForAllValues:StringLike': { 'dynamodb:LeadingKeys': ['JOB#*'] } },
      }),
    );

    const logGroup = new logs.LogGroup(this, 'Logs', {
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });
    const container = {
      image,
      jobRole,
      logging: ecs.LogDriver.awsLogs({ streamPrefix: 'engine', logGroup }),
      environment: { OSB_BUCKET: footage.bucketName, OSB_TABLE: table.tableName, AWS_DEFAULT_REGION: cdk.Stack.of(this).region },
    };

    // --- GPU: Spot, scaling to zero ---------------------------------------------

    const launchTemplate = new ec2.LaunchTemplate(this, 'GpuTemplate', {
      // The ECS AMI keeps images and container storage on the root volume.
      blockDevices: [
        {
          deviceName: '/dev/xvda',
          volume: ec2.BlockDeviceVolume.ebs(SCRATCH_GB, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
            deleteOnTermination: true,
          }),
        },
      ],
      requireImdsv2: true,
    });
    const gpu = new batch.ManagedEc2EcsComputeEnvironment(this, 'Gpu', {
      ...network,
      spot: true,
      allocationStrategy: batch.AllocationStrategy.SPOT_PRICE_CAPACITY_OPTIMIZED,
      instanceTypes: GPU_INSTANCE_TYPES.map((t) => new ec2.InstanceType(t)),
      useOptimalInstanceClasses: false,
      images: [{ imageType: batch.EcsMachineImageType.ECS_AL2023_NVIDIA }],
      minvCpus: 0,
      maxvCpus: GPU_MAX_VCPUS,
      launchTemplate,
    });
    const gpuQueue = new batch.JobQueue(this, 'GpuQueue', {
      computeEnvironments: [{ computeEnvironment: gpu, order: 1 }],
      // A job that can never start, or has waited half a day for a Spot
      // instance, fails and its owner is told, instead of waiting forever.
      jobStateTimeLimitActions: [
        {
          action: batch.JobStateTimeLimitActionsAction.CANCEL,
          state: batch.JobStateTimeLimitActionsState.RUNNABLE,
          reason: batch.JobStateTimeLimitActionsReason.JOB_RESOURCE_REQUIREMENT,
          maxTime: cdk.Duration.hours(1),
        },
        {
          action: batch.JobStateTimeLimitActionsAction.CANCEL,
          state: batch.JobStateTimeLimitActionsState.RUNNABLE,
          reason: batch.JobStateTimeLimitActionsReason.COMPUTE_ENVIRONMENT_MAX_RESOURCE,
          maxTime: cdk.Duration.hours(12),
        },
        {
          action: batch.JobStateTimeLimitActionsAction.CANCEL,
          state: batch.JobStateTimeLimitActionsState.RUNNABLE,
          reason: batch.JobStateTimeLimitActionsReason.INSUFFICIENT_INSTANCE_CAPACITY,
          maxTime: cdk.Duration.hours(12),
        },
      ],
    });

    // --- CPU: Fargate, for refits and the stub engine ---------------------------

    const cpu = new batch.FargateComputeEnvironment(this, 'Cpu', { ...network, maxvCpus: 8 });
    const cpuQueue = new batch.JobQueue(this, 'CpuQueue', { computeEnvironments: [{ computeEnvironment: cpu, order: 1 }] });
    this.queues = [gpuQueue, cpuQueue];

    // --- Job definitions --------------------------------------------------------

    const onGpu = (name: string, command: EngineCommand, timeout: cdk.Duration) =>
      new batch.EcsJobDefinition(this, name, {
        timeout,
        // A reclaimed Spot instance is retried (the engine resumes from its
        // checkpoints in work/); anything else fails at once.
        retryAttempts: 5,
        retryStrategies: [
          batch.RetryStrategy.of(batch.Action.RETRY, batch.Reason.SPOT_INSTANCE_RECLAIMED),
          batch.RetryStrategy.of(batch.Action.EXIT, batch.Reason.custom({ onReason: '*' })),
        ],
        container: new batch.EcsEc2ContainerDefinition(this, `${name}Container`, {
          ...container,
          command: [command],
          cpu: 4,
          // A g5.xlarge or g6.xlarge has 16 GiB; the rest is the host's.
          memory: cdk.Size.mebibytes(14_000),
          gpu: 1,
          volumes: [batch.EcsVolume.host({ name: 'scratch', hostPath: '/scratch', containerPath: '/scratch' })],
          linuxParameters: new batch.LinuxParameters(this, `${name}Linux`, { sharedMemorySize: cdk.Size.gibibytes(2) }),
        }),
      });
    const onCpu = (name: string, command: EngineCommand, timeout: cdk.Duration) =>
      new batch.EcsJobDefinition(this, name, {
        timeout,
        retryAttempts: 1,
        container: new batch.EcsFargateContainerDefinition(this, `${name}Container`, {
          ...container,
          command: [command],
          cpu: 2,
          memory: cdk.Size.gibibytes(8),
          ephemeralStorageSize: cdk.Size.gibibytes(40),
          // No NAT gateway: the task pulls its image over its own address.
          assignPublicIp: true,
          fargateCpuArchitecture: ecs.CpuArchitecture.X86_64,
        }),
      });

    const long = props.engineCompute === 'gpu' ? onGpu : onCpu;
    const longQueue = props.engineCompute === 'gpu' ? gpuQueue : cpuQueue;
    const prepare = long('Prepare', 'prepare', cdk.Duration.hours(1));
    const run = long('Run', 'run', cdk.Duration.hours(12));
    const refit = onCpu('Refit', 'refit', cdk.Duration.minutes(15));
    this.definitions = [prepare, run, refit];
    this.jobs = {
      prepare: { queue: longQueue.jobQueueArn, definition: prepare.jobDefinitionArn },
      run: { queue: longQueue.jobQueueArn, definition: run.jobDefinitionArn },
      refit: { queue: cpuQueue.jobQueueArn, definition: refit.jobDefinitionArn },
    };
  }

  /** Lets a function start the engine's jobs. */
  grantSubmit(grantee: iam.IGrantable) {
    grantee.grantPrincipal.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['batch:SubmitJob'],
        resources: [...this.definitions.map((d) => d.jobDefinitionArn), ...this.queues.map((q) => q.jobQueueArn)],
      }),
    );
  }

  /** Lets a function stop a job: cancelling, deleting, or a recording that
   *  became ready again. */
  grantTerminate(grantee: iam.IGrantable) {
    grantee.grantPrincipal.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ['batch:TerminateJob'],
        resources: [cdk.Stack.of(this).formatArn({ service: 'batch', resource: 'job', resourceName: '*' })],
      }),
    );
  }
}
