#!/usr/bin/env bash
set -euo pipefail

platform="${1:-}"

if [[ "$platform" != "android" && "$platform" != "ios" ]]; then
  echo "Usage: bash scripts/check_environment.sh <android|ios>" >&2
  exit 64
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command flutter
require_command dart

echo "Flutter: $(flutter --version | sed -n '1p')"

if [[ "$platform" == "android" ]]; then
  require_command java
  if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
    echo "Set ANDROID_HOME (or ANDROID_SDK_ROOT) to your Android SDK." >&2
    exit 1
  fi
  echo "Java: $(java -version 2>&1 | sed -n '1p')"
  echo "Android SDK: ${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
else
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "iOS setup requires macOS." >&2
    exit 1
  fi
  require_command xcodebuild
  require_command pod
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo "CocoaPods: $(pod --version)"
fi

echo "Environment check passed for $platform."
