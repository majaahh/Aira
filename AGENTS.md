# Repository Guidelines

## Project structure

Aira is a Flutter headphone controller for Android, Linux, and Windows. Start at `lib/main.dart`. Under `lib/src/core/`, models describe device capabilities and status, services handle platform I/O, and `controllers/headphone_controller.dart` exposes connection state and commands to the UI. Keep screens, reusable widgets, and theme code in their respective directories under `lib/src/ui/`.

Android Bluetooth operations span the Dart service and the Kotlin bridge in `android/app/src/main/kotlin/io/majaahh/aira/MainActivity.kt`. The desktop service uses `assets/scripts/aira_control.py`. When changing a command shared by both backends, check its arguments and response fields on both paths. Device artwork lives in `assets/images/devices/`.

## Development and build commands

Run commands from the repository root with a Flutter SDK that satisfies `pubspec.yaml`.

- `flutter pub get` installs the locked dependencies.
- `flutter devices` lists available targets. Use `flutter run -d <device-id>` for local development.
- `flutter analyze` checks Dart code using the repository’s `flutter_lints` configuration.
- `./scripts/build_android.sh --universal` builds a debug APK for all supported ABIs. Add `--release` for a release APK.
- `./scripts/build_linux.sh --tar` builds the standalone Linux tarball. Windows builds use `scripts/build_windows.ps1`. Packaging files live under `packaging/`.

## Coding style

Use two-space indentation for Dart. Name files in `snake_case`, classes in `UpperCamelCase`, and methods and variables in `lowerCamelCase`. Run `dart format` on the Dart files you change. In Bash scripts, follow the existing four-space indentation, quote paths, and reuse helpers from `scripts/utils/build_utils.sh`.

## Testing

The project declares `flutter_test` and currently has no tracked test suite or coverage threshold. Place new tests under `test/` with names such as `headphone_controller_test.dart`. Run a single file with `flutter test test/headphone_controller_test.dart`, or run all tests with `flutter test`. For Bluetooth changes, record the headset model, host platform, and whether verification used hardware or simulated replies.

## Commits and pull requests

Both existing commit subjects use the `aira:` prefix. Follow that pattern with a concise subject such as `aira: Fix reconnect after resume`. In a pull request, describe the user-visible change, affected platforms, and checks performed. Link a related issue when applicable and include a screenshot or short recording for visual changes.
