#!/bin/bash
set -euo pipefail

# Combine the per-arch images into a single multi-arch manifest on GHCR.
# docker buildx imagetools create is a pure registry operation — no local
# builder or QEMU emulation is required.
#
# Standalone usage:
#   IMAGE=ghcr.io/owner/unifi-os-server VERSION=5.1.15 \
#   REGISTRY_USER=myuser REGISTRY_TOKEN=mytoken \
#   bash .github/scripts/create-manifest.sh
#
# Env:
#   IMAGE          — full GHCR image name (e.g. ghcr.io/owner/unifi-os-server)
#   VERSION        — UOS Server version string (e.g. 5.1.15)
#   REGISTRY_USER  — registry username (in CI: github.actor)
#   REGISTRY_TOKEN — registry password/token (in CI: github.token)

[ -n "${IMAGE:-}"          ] || { echo "ERROR: IMAGE is not set"          >&2; exit 1; }
[ -n "${VERSION:-}"        ] || { echo "ERROR: VERSION is not set"        >&2; exit 1; }
[ -n "${REGISTRY_USER:-}"  ] || { echo "ERROR: REGISTRY_USER is not set"  >&2; exit 1; }
[ -n "${REGISTRY_TOKEN:-}" ] || { echo "ERROR: REGISTRY_TOKEN is not set" >&2; exit 1; }

echo "$REGISTRY_TOKEN" | docker login ghcr.io -u "$REGISTRY_USER" --password-stdin

docker buildx imagetools create \
  -t "$IMAGE:$VERSION" \
  -t "$IMAGE:latest" \
  "$IMAGE:$VERSION-amd64" \
  "$IMAGE:$VERSION-arm64"

echo "Manifest pushed: $IMAGE:$VERSION and $IMAGE:latest"
