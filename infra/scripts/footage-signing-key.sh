#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
#
# Makes the key pair that signs footage download URLs (infra/README.md,
# "Footage downloads"). The private key goes straight into SSM as a
# SecureString, /<stack name>/footage-signing-key, and is not kept on disk;
# the public key is written to infra/footage-signing-public.pem, which the
# next `cdk deploy` gives to CloudFront.
#
#   infra/scripts/footage-signing-key.sh [stack name]    # default OpenSportsBall
#
# Uses the AWS CLI's usual credentials and region (AWS_PROFILE, AWS_REGION).
# Running it again replaces both halves: deploy right after, since URLs
# signed with the new key fail until CloudFront has the new public key.

set -euo pipefail

stack="${1:-OpenSportsBall}"
param="/${stack}/footage-signing-key"
infra="$(cd "$(dirname "$0")/.." && pwd)"
pub="${infra}/footage-signing-public.pem"

# The key must be in the stack's region, where its Lambdas read it.
if [ -z "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ] && [ -z "$(aws configure get region 2>/dev/null)" ]; then
  echo "No AWS region: set AWS_PROFILE to the profile you deploy with (or AWS_REGION to the stack's region)." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 700 "$tmp"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/private.pem" 2>/dev/null
openssl pkey -in "$tmp/private.pem" -pubout -out "$tmp/public.pem"

aws ssm put-parameter --name "$param" --type SecureString --overwrite \
  --description "Signs ${stack} footage download URLs (CloudFront)" \
  --value "file://$tmp/private.pem" >/dev/null
mv "$tmp/public.pem" "$pub"

echo "Private key: SSM ${param}"
echo "Public key:  ${pub}"
echo "Now deploy: cd infra && ${AWS_PROFILE:+AWS_PROFILE=$AWS_PROFILE }npx cdk deploy"
