#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Deltarune Mod Manager.app"
PKG="$ROOT/Deltarune Mod Manager.pkg"

"$ROOT/scripts/build-app.sh"

if [[ ! -x "$APP/Contents/MacOS/DeltaruneModManager" ]]; then
    printf 'Built app executable is missing.\n' >&2
    exit 1
fi

if [[ ! -f "$PKG" ]]; then
    printf 'Built installer package is missing.\n' >&2
    exit 1
fi
printf 'Built installer: %s\n' "$PKG"
