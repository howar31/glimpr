#!/usr/bin/env bash
# Rasterize the Glimpr brand SVGs into the macOS asset catalog.
# Requires: rsvg-convert (librsvg). Run from anywhere: tool/branding/generate.sh
set -euo pipefail
cd "$(dirname "$0")"

ROOT=../../macos/Runner/Assets.xcassets
APPICON="$ROOT/AppIcon.appiconset"
DARK="$ROOT/AppIconDark.imageset"
LIGHT="$ROOT/AppIconLight.imageset"
STATUS="$ROOT/StatusBarIcon.imageset"
mkdir -p "$DARK" "$LIGHT" "$STATUS"

render() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# Default static app icon = dark-glass primary (shown in Finder/Launchpad/About;
# the running-app Dock icon is swapped to the light variant at runtime).
for s in 16 32 64 128 256 512 1024; do
  render icon-dark.svg "$s" "$APPICON/app_icon_${s}.png"
done

# Runtime-switchable Dock variants, loaded by NSImage(named:).
render icon-dark.svg  1024 "$DARK/icon_1024.png"
render icon-light.svg 1024 "$LIGHT/icon_1024.png"

# Menu-bar template mark (auto-tinted by macOS to the menu-bar appearance).
render mark-mono.svg 18 "$STATUS/icon_18.png"
render mark-mono.svg 36 "$STATUS/icon_36.png"

echo "Branding assets generated into $ROOT"
