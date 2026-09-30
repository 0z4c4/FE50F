#!/usr/bin/env bash
# Genera la carpeta android/ y aplica manifest + parches. Requiere Flutter SDK en PATH.
set -euo pipefail
cd "$(dirname "$0")"
flutter create --platforms=android --org com.fe50f --project-name fe50f .
rm -f test/widget_test.dart
cp android_overlay/AndroidManifest.xml android/app/src/main/AndroidManifest.xml
python3 tools/patch_gradle.py
flutter pub get
echo "OK. Ahora: flutter build apk --release"
