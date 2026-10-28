#!/bin/bash
# Fetches DocAligner's two corner models (DocsaidLab/DocAligner release 1.1.1, Apache-2.0, see
# Sources/CompleteScannerIOS/Models/DocAligner-LICENSE.txt) into Sources/CompleteScannerIOS/Models for
# the iPhone's page detector test. They are not checked in; without them the app says the model is not
# there and the tests that need them skip. Each file is checked against its SHA-256.
set -euo pipefail

release="https://github.com/DocsaidLab/DocAligner/releases/download/1.1.1"
models="$(cd "$(dirname "$0")/.." && pwd)/Sources/CompleteScannerIOS/Models"

fetch() {
  local name="$1" expected="$2"
  local file="$models/$name"
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d ' ' -f 1)" = "$expected" ]; then
    echo "$name: already fetched"
    return
  fi
  curl -fsSL -o "$file.part" "$release/$name"
  local hash
  hash=$(shasum -a 256 "$file.part" | cut -d ' ' -f 1)
  if [ "$hash" != "$expected" ]; then
    rm -f "$file.part"
    echo "$name: checksum mismatch: $hash" >&2
    exit 1
  fi
  mv "$file.part" "$file"
  echo "$name: fetched"
}

fetch lcnet100_h_e_bifpn_256_fp32.onnx f4117b786e3a18470f3865c93f3c2bd69d9b998edd60f385574a5c665e79594e
fetch fastvit_t8_h_e_bifpn_256_fp32.onnx 950070fd4a46e25d46db7c35d0ed77612d9063f70d4543c7c504f0da6a943a89
