#!/bin/sh
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
#
# Xcode build phase: copies the packaged processing engine (osb-engine,
# AGPL, built by opensportsball-processing's packaging/mac/build_engine.sh)
# into the app, at Contents/Resources/osb-engine, where the app looks for it
# first. The app runs it as a separate program and talks to it only through
# files and its progress lines (docs/LICENSING.md).
#
# OSB_ENGINE_DIR (a build setting: Runner/Configs/Engine.xcconfig, git-
# ignored, see Engine.example.xcconfig) names the osb-engine folder. Unset,
# as in CI, the app is built without it and finds an engine in Settings or
# $OSB_ENGINE instead.
set -eu
DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/osb-engine"
if [ -z "${OSB_ENGINE_DIR:-}" ]; then
  echo "note: OSB_ENGINE_DIR not set: building without the engine (Settings or \$OSB_ENGINE find one)"
  rm -rf "$DEST"
  exit 0
fi
if [ ! -x "$OSB_ENGINE_DIR/osb-engine" ]; then
  echo "error: OSB_ENGINE_DIR=$OSB_ENGINE_DIR has no osb-engine launcher (build it with packaging/mac/build_engine.sh)" >&2
  exit 1
fi
# The engine must not write its own folder once it's inside the signed
# app: its launcher sets PYTHONDONTWRITEBYTECODE and its .pyc files are
# compiled ahead. One built before that would.
if ! grep -q PYTHONDONTWRITEBYTECODE "$OSB_ENGINE_DIR/osb-engine"; then
  echo "error: $OSB_ENGINE_DIR is an older engine that writes into its own folder; rebuild it" >&2
  exit 1
fi
# Only what changed is copied (the first copy is ~1.6 GB).
mkdir -p "$DEST"
rsync -a --delete "$OSB_ENGINE_DIR/" "$DEST/"
echo "osb-engine $(cat "$DEST/VERSION" 2>/dev/null || echo '?') -> $DEST"
