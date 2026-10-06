# Sporra Preview

The Flutter iOS preview lives here. It installs alongside the original Sporra
app and connects to your Sporra server. Use server version **0.136.0 or newer**.
Open `ios/Runner.xcworkspace` for the native project; Flutter development starts
at `lib/main.dart`.

## Install on an iOS simulator

Install Flutter and Xcode, start an iOS simulator, then run from this folder:

```sh
./Tools/install-simulator.sh
```

You can pass a simulator UUID as the first argument. The script uses the selected Xcode installation; set `DEVELOPER_DIR` to use
another installation.
Sign in with your server URL and existing account. For a server running on this
Mac, use `http://127.0.0.1:PORT`. Map tiles require internet access.

## Preview scope

The preview includes account sign-in/registration, native maps and visited
blobs, region/country/continent fills, activity colours and visibility,
continuous speed/elevation routes with map scrubbing, annual charts, route selection,
yellow trip/day tracks, recorded-day calendar, search, trips,
statistics with regional breakdown and activity sorting, paint/erase and region clearing with undo,
source management, undoable activity edits and deletion, reviewed multi-file imports with source and route options, local photo browsing, tracking and sync settings, Strava and
Home Assistant setup and schedule/status/disconnect controls, airport category switches and labels, random activity colours, device cache clearing, snapshots, and backup sharing for administrators.
The Swift bridge owns location, HealthKit, photo indexing, cookies and uploads.
Photo thumbnails remain on the device.

Menus and cards use the web app’s neutral glass surfaces and backdrop blur.
The detailed feature-by-feature comparison is in
[FLUTTER_WEB_PARITY.md](../FLUTTER_WEB_PARITY.md).

This is an early port. Advanced export layouts, Komoot tour import, Mapbox Standard 3D,
full administration and complete visual/localization
parity still need work. Simulator location, HealthKit and photo availability
are limited by the simulator's configured data.

## Verify

```sh
flutter analyze
flutter test
```

The integration test additionally needs a disposable server at port 3209 with
registration enabled. It creates a test account and exercises authentication,
render data, visible region/country/continent fills, activity graphs and map
scrubbing, edits and undo, menus, session restoration and sign-out.
Run it with `flutter drive --driver=test_driver/integration_test.dart
--target=integration_test/app_test.dart -d <simulator-id>`; screenshots are saved
to `/tmp/sporra-parity-*.png`. Never run
it against a personal database.

Physical-device builds require your Apple signing team and provisioning profile
in Xcode. The preview uses bundle ID `com.zhekch.sporra.flutter`.
