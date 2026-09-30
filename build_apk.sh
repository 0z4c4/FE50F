#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ -d android ] || ./setup_android.sh
flutter build apk --release
echo "APK: build/app/outputs/flutter-apk/app-release.apk"
