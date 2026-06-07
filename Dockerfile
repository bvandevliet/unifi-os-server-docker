ARG BASE_IMAGE=uosserver-base:latest
FROM ${BASE_IMAGE}

# ── Metadata ──────────────────────────────────────────────────────────────────
LABEL org.opencontainers.image.source="https://github.com/bvandevliet/unifi-os-server-docker"
LABEL org.opencontainers.image.description="Self-hosted UniFi OS Server — single volume, capability-based security, multi-arch (amd64/arm64), auto-updated"
LABEL org.opencontainers.image.licenses="MIT"

# ── Version ───────────────────────────────────────────────────────────────────
# Single source of truth: check-update.yml reads and bumps this value.
# Build pipeline parses it with: grep -oP '^ARG UOS_SERVER_VERSION=\K[0-9.]+'
ARG UOS_SERVER_VERSION=5.1.15
ENV UOS_SERVER_VERSION=${UOS_SERVER_VERSION}

# Required: systemd (PID 1) must receive SIGRTMIN+3 to initiate a clean shutdown.
STOPSIGNAL SIGRTMIN+3

# ── Entrypoint ────────────────────────────────────────────────────────────────
# Thin overlay only — no packages installed, no services modified.
# All runtime logic (volume symlinks, UUID, arch detection, system IP, etc.)
# lives in entrypoint.sh; see entrypoint.sh for details.
#
# IMPORTANT: The UniFi Network application ships *inside* the base firmware
# image (UNIFI_CORE_ENABLED=true, ucore API on :8081). Do NOT reinstall it
# from the public standalone .deb — that variant runs without ucore integration
# and breaks the first-boot setup wizard.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
