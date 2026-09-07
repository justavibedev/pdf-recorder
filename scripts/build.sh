#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project PDFRecorder.xcodeproj -scheme PDFRecorder -configuration Release \
  -derivedDataPath build/DerivedData -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
mkdir -p build
ditto 'build/DerivedData/Build/Products/Release/PDF Recorder.app' 'build/PDF Recorder.app'
echo 'Built build/PDF Recorder.app'
