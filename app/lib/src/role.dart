// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/// The two roles a phone can take in a recording session. Values match the
/// `role` field in shared/schemas/manifest.schema.json.
enum DeviceRole {
  main(
    'Main phone',
    'Controls the recording. Starts and stops both phones and writes the '
        'upload manifest.',
  ),
  secondary(
    'Secondary phone',
    'Records the other half of the field. Follows the Main phone.',
  );

  const DeviceRole(this.label, this.description);

  final String label;
  final String description;
}
