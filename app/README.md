# app

Flutter app for iOS and Android. One app; each phone picks the **Main** or
**Secondary** role. License: Apache-2.0.

The platform folders (`ios/`, `android/`) are not generated yet. Once
Flutter is installed:

```
cd app
flutter create --platforms=ios,android --org dev.sportsballvideo .
flutter pub get
```

`flutter create` leaves existing files alone and adds the platform folders.
Add the SPDX header to any generated source file you edit.

## Phase 1 scope

- BLE pairing (QR code from Main) and control: start, stop, heartbeat,
  battery / storage / thermal status, clock-sync ping/pong.
- Recording through `plugins/dual_camera` in 5-minute segments with
  exposure, focus and white balance locked and stabilization off.
- Upload queue: S3 multipart via presigned URLs, Wi-Fi only by default.
  Android: WorkManager with an unmetered-network constraint. iOS:
  background `URLSession` uploading from file.
- Main writes and uploads the manifest
  (`shared/schemas/manifest.schema.json`).
