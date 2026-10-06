# infra

AWS CDK (TypeScript) stack: one `cdk deploy` plus a config file, so anyone
can self-host. License: Apache-2.0. Not started (Phase 2).

Resources: S3 (raw segments with a lifecycle rule that deletes raw footage N
days after a successful render), Cognito, API Gateway + Lambda, DynamoDB,
Step Functions, AWS Batch GPU compute environment on Spot with min vCPUs 0,
ECR, a Fargate task for YouTube upload, SES or push notifications, KMS.

Nothing should run between games except storage and pay-per-request
DynamoDB.
