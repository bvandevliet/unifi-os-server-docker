#!/bin/bash
set -euo pipefail

# Build the final image from the extracted base and push the arch-specific tag
# to GHCR.
#
# Standalone usage:
#   IMAGE=ghcr.io/owner/unifi-os-server VERSION=5.1.15 ARCH=amd64 \
#   REGISTRY_USER=myuser REGISTRY_TOKEN=mytoken \
#   bash .github/scripts/build-push.sh
#
# Env:
#   IMAGE          — full GHCR image name (e.g. ghcr.io/owner/unifi-os-server)
#   VERSION        — UOS Server version string (e.g. 5.1.15)
#   ARCH           — target architecture tag suffix (amd64 or arm64)
#   REGISTRY_USER  — registry username (in CI: github.actor)
#   REGISTRY_TOKEN — registry password/token (in CI: github.token)

[ -n "${IMAGE:-}"          ] || { echo "ERROR: IMAGE is not set"          >&2; exit 1; }
[ -n "${VERSION:-}"        ] || { echo "ERROR: VERSION is not set"        >&2; exit 1; }
[ -n "${ARCH:-}"           ] || { echo "ERROR: ARCH is not set"           >&2; exit 1; }
[ -n "${REGISTRY_USER:-}"  ] || { echo "ERROR: REGISTRY_USER is not set"  >&2; exit 1; }
[ -n "${REGISTRY_TOKEN:-}" ] || { echo "ERROR: REGISTRY_TOKEN is not set" >&2; exit 1; }

echo "$REGISTRY_TOKEN" | docker login ghcr.io -u "$REGISTRY_USER" --password-stdin

docker build \
  --build-arg BASE_IMAGE=uosserver-base:local \
  --build-arg UOS_SERVER_VERSION="$VERSION" \
  -t "$IMAGE:$VERSION-$ARCH" .

docker push "$IMAGE:$VERSION-$ARCH"
echo "Pushed: $IMAGE:$VERSION-$ARCH"
