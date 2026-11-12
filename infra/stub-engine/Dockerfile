# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0

# The stub engine (stub.mjs). Built for linux/amd64, the architecture the
# Batch job definitions ask for; see ../scripts/push-stub-engine.sh.
FROM node:22-alpine
WORKDIR /engine
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY stub.mjs scene.mjs video.mjs ./
USER node
ENTRYPOINT ["node", "/engine/stub.mjs"]
