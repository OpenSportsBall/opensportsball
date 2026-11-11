#!/bin/sh
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
#
# Xcode build phase: compiles `osb` (packages/osb_core/bin/osb.dart: sign
# in, list games and download footage without the window) and puts it in
# the app beside the app's own program, at Contents/MacOS/osb. From there
# it finds the engine the app carries (Contents/Resources/osb-engine), so
# a script or a model needs nothing but the app.
#
# It is one file that writes nothing beside itself. Compiled again only
# when its sources changed (a few seconds).
set -eu
DART="$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart"
SRC="$PROJECT_DIR/../../packages/osb_core"
# The app's own package list: it has osb_core and everything osb_core uses,
# so the package needs no `pub get` of its own here.
PACKAGES="$PROJECT_DIR/../.dart_tool/package_config.json"
BUILT="$DERIVED_FILE_DIR/osb"
DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/osb"

if [ ! -x "$BUILT" ] || [ -n "$(find "$SRC/bin" "$SRC/lib" "$SRC/pubspec.yaml" "$PACKAGES" "$0" -newer "$BUILT" -print -quit)" ]; then
  mkdir -p "$DERIVED_FILE_DIR"
  "$DART" compile exe --packages="$PACKAGES" -o "$BUILT.new" "$SRC/bin/osb.dart" >/dev/null
  mv "$BUILT.new" "$BUILT"
fi
mkdir -p "$(dirname "$DEST")"
cmp -s "$BUILT" "$DEST" || cp "$BUILT" "$DEST"
echo "osb -> $DEST"
