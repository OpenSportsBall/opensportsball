#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
#
# Builds the stub engine (infra/stub-engine) and pushes it to the stack's
# engine repository as :stub, the tag the stack uses by default. Run once
# after the first deploy, signed in to the AWS account. Needs Docker.
#
#   infra/scripts/push-stub-engine.sh [stack name]
set -euo pipefail

stack="${1:-OpenSportsBall}"
here="$(cd "$(dirname "$0")" && pwd)"

uri="$(aws cloudformation describe-stacks --stack-name "$stack" \
  --query "Stacks[0].Outputs[?OutputKey=='EngineRepositoryUri'].OutputValue" --output text)"
if [ -z "$uri" ] || [ "$uri" = "None" ]; then
  echo "Stack $stack has no EngineRepositoryUri output. Deploy it first (infra/README.md)." >&2
  exit 1
fi
registry="${uri%%/*}"
region="$(echo "$registry" | cut -d. -f4)"

aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
# The job definitions run linux/amd64, whatever this machine is.
docker build --platform linux/amd64 -t "$uri:stub" "$here/../stub-engine"
docker push "$uri:stub"
echo "Pushed $uri:stub"
