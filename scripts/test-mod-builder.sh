#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dmt-validation.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

cd "$ROOT"
swiftc \
  Sources/DeltaruneModManager/AppUpdate.swift \
  Sources/DeltaruneModManager/ModModels.swift \
  Sources/DeltaruneModManager/GameBananaCatalog.swift \
  Tests/ModModelsValidation.swift \
  -o "$TEMP_DIR/ModModelsValidation"
"$TEMP_DIR/ModModelsValidation"
