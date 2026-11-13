#!/bin/bash
# Remove rebuildable build output to reclaim disk space.
#   scripts/clean.sh            delete
#   scripts/clean.sh -n         dry run, only show what would go
# Removes: SwiftPM .build/ and .swiftpm/ (root, Kit, Shared, every Extension),
# build/ (app bundle + extensions from build_app.sh), and __pycache__.
# Keeps: re/, vendor/, tools/, releases/ (not regenerable from source alone).
set -euo pipefail
cd "$(dirname "$0")/.."

dry=0
[[ "${1:-}" == "-n" || "${1:-}" == "--dry-run" ]] && dry=1

targets=()
while IFS= read -r -d '' d; do
  targets+=("$d")
done < <(find . \( -path ./re -o -path ./.git -o -path ./vendor -o -path ./tools -o -path ./InspirationVideos \) -prune -o \
  -type d \( -name .build -o -name .swiftpm -o -name __pycache__ -o -path ./build \) -print0 -prune)

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "Nothing to clean."
  exit 0
fi

before=$(du -sck "${targets[@]}" | tail -1 | cut -f1)
for d in "${targets[@]}"; do
  printf '%8s  %s\n' "$(du -sh "$d" | cut -f1)" "$d"
done

human() { awk -v k="$1" 'BEGIN{printf "%.1f GB", k/1048576}'; }

if (( dry )); then
  echo "Would free $(human "$before")"
  exit 0
fi

rm -rf "${targets[@]}"
echo "Freed $(human "$before")"
