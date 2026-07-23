#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"
app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$app_dir/.." && pwd)"

if [[ "$platform" != "android" && "$platform" != "ios" ]]; then
  echo "Usage: bash sdk/flutter/example/setup.sh <android|ios>" >&2
  exit 64
fi

bash "$repo_root/scripts/check_environment.sh" "$platform"

echo "Installing Flutter dependencies..."
(
  cd "$app_dir"
  flutter pub get
)

if [[ "$platform" == "ios" ]]; then
  echo "Installing CocoaPods dependencies..."
  (
    cd "$app_dir/ios"
    pod install
  )
  echo "Select your Apple development Team in sdk/flutter/example/ios/Runner.xcworkspace."
fi

echo "Setup complete. Run: cd sdk/flutter/example && flutter run"
