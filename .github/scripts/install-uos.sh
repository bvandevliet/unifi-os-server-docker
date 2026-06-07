#!/bin/bash
set -euo pipefail

# Free runner disk space, then download and run the official UOS Server installer.
# The installer sets up uosserver as a rootless Podman container under /home/uosserver/.
#
# Standalone usage:
#   DOWNLOAD_URL=https://... bash .github/scripts/install-uos.sh
#
# Env:
#   DOWNLOAD_URL — direct download URL for the platform-specific installer binary

[ -n "${DOWNLOAD_URL:-}" ] || { echo "ERROR: DOWNLOAD_URL is not set" >&2; exit 1; }

# Empty when already root (e.g. inside a container); 'sudo' otherwise.
SUDO=$(command -v sudo || true)

# The UOS installer + extracted image together often exceed default runner free
# space; reclaim space occupied by toolchains we don't need.
$SUDO rm -rf \
  /usr/share/dotnet \
  /usr/local/lib/android \
  /opt/ghc \
  /opt/hostedtoolcache/CodeQL

# Podman's storage.conf must exist before the installer runs, otherwise it fails
# to initialise its storage backend.
mkdir -p "$HOME/.config/containers"
touch "$HOME/.config/containers/storage.conf"

curl -fSL -o unifi-os-server "$DOWNLOAD_URL"
$SUDO chmod +x unifi-os-server

# The installer exits non-zero on success when run non-interactively; suppress
# that exit code so the step does not fail spuriously.
echo "y" | $SUDO ./unifi-os-server || true
