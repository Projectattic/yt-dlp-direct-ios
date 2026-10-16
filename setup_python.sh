#!/bin/bash
# Downloads the official Python-for-iOS package (BeeWare Python-Apple-support,
# Python 3.14) and puts Python.xcframework next to the Xcode project.
# Run once from Terminal:   cd <this folder> && ./setup_python.sh
set -euo pipefail
cd "$(dirname "$0")"

TAG="3.14-b10"
ASSET="Python-3.14-iOS-support.b10.tar.gz"
URL="https://github.com/beeware/Python-Apple-support/releases/download/$TAG/$ASSET"

if [ -d Python.xcframework ]; then
  echo "Python.xcframework is already here. Delete it first if you want to re-download."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $ASSET (about 37 MB)…"
curl -fL --progress-bar "$URL" -o "$TMP/python.tar.gz"

echo "Unpacking…"
mkdir "$TMP/x"
tar -xzf "$TMP/python.tar.gz" -C "$TMP/x"
mv "$TMP/x/Python.xcframework" ./Python.xcframework

echo
echo "Done: Python.xcframework is in place ($(grep 'Python version' "$TMP/x/VERSIONS" || true))."
echo "Now open YtDlDirect.xcodeproj in Xcode and press Run."
