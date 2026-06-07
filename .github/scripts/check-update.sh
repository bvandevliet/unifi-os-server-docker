#!/bin/bash
set -euo pipefail

# Read the current pinned version from Dockerfile, query Ubiquiti's firmware API
# for the latest release, and — if they differ — bump Dockerfile, commit, tag,
# push, and dispatch build.yml with the new version.
#
# Standalone usage (from repo root, with a token that has contents:write):
#   GH_TOKEN=ghp_... bash .github/scripts/check-update.sh
#
# Env:
#   GH_TOKEN     — GitHub token with contents:write (required for git push / gh CLI)
#   FIRMWARE_API — Ubiquiti firmware API base URL (has default)

FIRMWARE_API="${FIRMWARE_API:-https://fw-update.ubnt.com/api/firmware-latest}"

CURRENT=$(grep -oP '^ARG UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile)
[ -n "$CURRENT" ] || { echo "ERROR: Could not parse UOS_SERVER_VERSION from Dockerfile" >&2; exit 1; }
echo "Current: $CURRENT"

RESPONSE=$(curl -fsSL "$FIRMWARE_API?filter=eq~~product~~unifi-os-server&filter=eq~~platform~~linux-x64&filter=eq~~channel~~release")

COUNT=$(echo "$RESPONSE" | jq '._embedded.firmware | length')
if [ "$COUNT" -eq 0 ]; then
  echo "ERROR: Ubiquiti API returned no firmware entries" >&2
  exit 1
fi

LATEST=$(echo "$RESPONSE" | jq -r '._embedded.firmware[0].version' | sed 's/^v//')
if [ -z "$LATEST" ] || [ "$LATEST" = "null" ]; then
  echo "ERROR: Could not parse version from API response" >&2
  exit 1
fi
echo "Latest:  $LATEST"

if [ "$LATEST" = "$CURRENT" ]; then
  echo "Already up to date ($CURRENT) — nothing to do."
  exit 0
fi

echo "Bumping: $CURRENT → $LATEST"
sed -i "s/^ARG UOS_SERVER_VERSION=.*/ARG UOS_SERVER_VERSION=$LATEST/" Dockerfile

git config user.name  "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add Dockerfile
git commit -m "chore: bump UOS Server $CURRENT → $LATEST"
git tag "v$LATEST" || echo "Tag v$LATEST already exists, skipping"
git push origin main
git push origin "v$LATEST" || true
echo "Pushed v$LATEST — build.yml will be triggered by the tag push."
