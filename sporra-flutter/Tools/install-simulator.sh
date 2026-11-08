#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
device="${1:-booted}"
flutter pub get
flutter build ios --simulator --debug
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" build/ios/iphonesimulator/Runner.app
xcrun simctl launch "$device" com.zhekch.sporra.flutter
