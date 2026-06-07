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

# The installer's Podman subprocess runs as the uosserver user and stats paths
# under HOME to find storage.conf. /home/runner is mode 750 by default so
# uosserver cannot traverse it — chmod 755 the full path chain and pre-create
# storage.conf with world-readable permissions so Podman can open it.
mkdir -p "$HOME/.config/containers"
chmod 755 "$HOME" "$HOME/.config" "$HOME/.config/containers"
# Set the storage driver explicitly to suppress Podman's "driver was picked automatically" warning.
printf '[storage]\ndriver = "overlay"\n' > "$HOME/.config/containers/storage.conf"
chmod 644 "$HOME/.config/containers/storage.conf"

curl -fSL -o unifi-os-server "$DOWNLOAD_URL"
$SUDO chmod +x unifi-os-server

# The installer exits non-zero on success when run non-interactively; suppress
# that exit code so the step does not fail spuriously.
echo "y" | $SUDO ./unifi-os-server || true
