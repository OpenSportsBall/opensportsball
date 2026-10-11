# Third-party code

Packages copied into the repo because the published version needed a change.
Each keeps its own license (see `REUSE.toml`), not the project's.

## bluetooth_low_energy_android

Upstream: <https://github.com/yanshouwang/bluetooth_low_energy>, version
6.2.1, MIT. Wired in through `dependency_overrides` in `app/pubspec.yaml`.

Only change: `android/build.gradle` became `android/build.gradle.kts` and
stops applying the Kotlin Gradle Plugin. Flutter warns that a future release
will refuse to build apps whose plugins apply it. The pigeon and lint dev
dependencies were dropped from its `pubspec.yaml` along with the
`resolution: workspace` line.

Delete this copy and the override once upstream ships built-in Kotlin
support.
