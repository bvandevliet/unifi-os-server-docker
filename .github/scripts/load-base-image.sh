#!/bin/bash
set -euo pipefail

# Copy the rootless Podman image written by the UOS installer from /home/uosserver/
# to the current user's Podman storage, then copy it into the Docker daemon via
# skopeo (no intermediate tar file required).
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

# skopeo copies directly from Podman's container storage into the Docker daemon
# without an intermediate tar archive. Both tools are pre-installed on ubuntu-24.04.
skopeo copy "containers-storage:$IMAGE_TAG" docker-daemon:uosserver-base:local
echo "Base image ready: uosserver-base:local (source: $IMAGE_TAG)"
