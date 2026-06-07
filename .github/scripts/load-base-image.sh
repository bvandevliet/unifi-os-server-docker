#!/bin/bash
set -euo pipefail

# Copy the rootless Podman image written by the UOS installer from /home/uosserver/
# to the current user's Podman storage, then load it into the Docker daemon.
#
# Standalone usage (after install-uos.sh has run):
#   bash .github/scripts/load-base-image.sh

# Empty when already root (e.g. inside a container); 'sudo' otherwise.
SUDO=$(command -v sudo || true)

USER_STORAGE="$HOME/.local/share/containers/storage"

for DIR in overlay overlay-images overlay-layers; do
  SRC="/home/uosserver/.local/share/containers/storage/$DIR"
  DST="$USER_STORAGE/$DIR"
  $SUDO test -d "$SRC" || continue
  mkdir -p "$DST"
  $SUDO cp -a "$SRC/." "$DST/"
done
[ -d "$USER_STORAGE" ] && $SUDO chown -R "$(whoami):$(whoami)" "$USER_STORAGE"

IMAGE_TAG=$(podman images --noheading --format "{{.Repository}}:{{.Tag}}" | grep -v '<none>' | head -1)
[ -n "$IMAGE_TAG" ] || { echo "ERROR: No podman image found — installer likely failed" >&2; exit 1; }

# Use podman save | docker load rather than skopeo copy containers-storage:.
# The skopeo containers-storage transport requires user namespace support (unshare)
# which GitHub runners do not permit. podman save exports a plain tar archive
# that docker load can consume without any user namespace operations.
podman save "$IMAGE_TAG" | docker load
docker tag "$IMAGE_TAG" uosserver-base:local
echo "Base image ready: uosserver-base:local (source: $IMAGE_TAG)"
