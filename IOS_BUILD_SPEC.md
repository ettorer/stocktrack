# iOS Build Handoff Specification

## Objective

Prepare, build, and verify the Stocktrack Flutter app for iOS on macOS. Keep
the current app behavior intact; make native project changes only when the
build or device testing demonstrates they are needed.

## Current project state

- Flutter app at the project root; Dart/Flutter sources are under `lib/`.
- iOS Xcode project and workspace are present:
  - `ios/Runner.xcworkspace`
  - Shared scheme: `Runner`
- Current iOS deployment target: iOS 15.0.
- iPhone and iPad device families are enabled.
- The Xcode bundle identifier is still the template value
  `com.example.stocktrack`. Do not choose a production identifier without
  confirmation from the project owner.
- Flutter version on the originating host: 3.50.0 stable. Confirm the
  installed version and Xcode compatibility on the macOS host.
- `ios/Flutter/Generated.xcconfig`, plugin registrants, and other generated
  Flutter files are ignored/generated. Regenerate them with Flutter tooling;
  do not hand-edit or commit generated files.
- Before Flutter commands that bundle assets, run
  `dart run tool/prepare_config.dart`. It creates the ignored
  `assets/config.json` from private `assets/config.local.json`, or from the
  empty tracked `assets/config.example.json` if no local config exists. Do not
  print, log, commit, or send key values in build output. Obtain any needed
  values securely from the project owner.
- Current providers are Finnhub and Yahoo Finance; Yahoo Finance data is daily
  history, not real-time. Holdings support USD and EUR.

## Work to perform on macOS

1. Work from the project root and preserve existing local changes.
2. Verify Xcode is installed and selected (`xcode-select -p`), accept the
   license if required, and review `flutter doctor -v`.
3. Run `dart run tool/prepare_config.dart`, then `flutter pub get`,
   `flutter analyze`, and `flutter test`.
4. Open `ios/Runner.xcworkspace` in Xcode and confirm the `Runner` scheme,
   deployment target, generated plugin integration, and asset catalog build.
5. Build and launch on an available iOS simulator. Test Quotes, Holdings,
   Add/Edit holding (including USD/EUR selection and keyboard presentation),
   Settings, and network error handling.
6. If a physical-device or distribution build is requested, ask the project
   owner for the intended bundle identifier, Apple Developer Team, signing
   method, and distribution target. Do not invent identifiers, alter
   entitlements, or request/store signing secrets in source control.
7. Produce a signed archive/IPA only when the owner has provided the
   necessary signing configuration. Otherwise deliver the simulator build and
   report signing as a remaining prerequisite.
8. Report the exact commands, Xcode/Flutter versions, simulator/device tested,
   build result, warnings, and any remaining blockers. Keep credentials out of
   the report.

## Build and verification guidance

- Check `flutter build ios --help` and `flutter build ipa --help` on the
  installed macOS Flutter SDK before choosing build flags.
- A simulator build should not require distribution signing. For device or
  distribution builds, use the owner-approved signing setup in Xcode or the
  appropriate Flutter build command.
- Do not upgrade Flutter, dependencies, the iOS deployment target, or
  generated Xcode project settings just to silence warnings. Make such changes
  only if required for a successful, tested build, and report them.
- Do not make live Yahoo Finance requests as part of automated tests. The
  project widget tests use injected/fake quote fetchers.

## Handoff limitation

The originating environment is Linux and does not expose Xcode or Flutter's
iOS build subcommand. iOS compilation, simulator validation, signing, and IPA
creation therefore must be completed by the macOS agent.
