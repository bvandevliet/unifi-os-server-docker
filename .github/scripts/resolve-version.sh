#!/bin/bash
set -euo pipefail

# Resolve the UOS Server version and GHCR image name.
# When ARCH_PLATFORM is set, also fetches the installer download URL for that arch.
#
# Standalone usage:
#   ARCH_PLATFORM=linux-x64 bash .github/scripts/resolve-version.sh
#   ARCH_PLATFORM=linux-arm64 INPUT_VERSION=5.1.15 bash .github/scripts/resolve-version.sh
#
# Env:
#   INPUT_VERSION           — optional override; falls back to Dockerfile ARG
#   ARCH_PLATFORM           — optional; linux-x64 or linux-arm64; if set, also outputs url
#   FIRMWARE_API            — Ubiquiti firmware API base URL (has default)
#   GITHUB_REPOSITORY_OWNER — falls back to parsing git remote origin

FIRMWARE_API="${FIRMWARE_API:-https://fw-update.ubnt.com/api/firmware-latest}"

# output KEY VALUE — prints to stdout and writes to GITHUB_OUTPUT when in CI.
output() {
  echo "$1=$2"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT" || true
}

VERSION="${INPUT_VERSION:-}"
if [ -z "$VERSION" ]; then
  VERSION=$(grep -oP '^ARG UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile)
fi
[ -n "$VERSION" ] || { echo "ERROR: Could not determine UOS Server version" >&2; exit 1; }

# Derive owner from env (CI) or git remote (standalone).
OWNER="${GITHUB_REPOSITORY_OWNER:-}"
if [ -z "$OWNER" ]; then
  OWNER=$(git remote get-url origin 2>/dev/null \
    | sed -E 's|.*github\.com[:/]([^/]+)/.*|\1|')
fi
[ -n "$OWNER" ] || { echo "ERROR: Could not determine repository owner" >&2; exit 1; }

# GHCR requires the owner name to be lowercase.
IMAGE="ghcr.io/${OWNER,,}/unifi-os-server"

output version "$VERSION"
output image   "$IMAGE"

if [ -n "${ARCH_PLATFORM:-}" ]; then
  RESPONSE=$(curl -fsSL "$FIRMWARE_API?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~$ARCH_PLATFORM&filter=eq~~channel~~release")
  COUNT=$(echo "$RESPONSE" | jq '._embedded.firmware | length')
  [ "$COUNT" -gt 0 ] || { echo "ERROR: Ubiquiti API returned no firmware entries for $ARCH_PLATFORM" >&2; exit 1; }
  URL=$(echo "$RESPONSE" | jq -r '._embedded.firmware[0]._links.data.href')
  [ -n "$URL" ] && [ "$URL" != "null" ] || { echo "ERROR: Missing download URL in API response" >&2; exit 1; }
  output url "$URL"
fi
