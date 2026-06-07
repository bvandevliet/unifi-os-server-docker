# AGENTS.md — unifi-os-server-docker

AI agent guide for this project: a minimal, auto-updating Docker image that
repackages the official Ubiquiti UniFi OS Server binary for standard container
infrastructure with multi-arch support (amd64/arm64).

---

## Design Goals

| Goal | How it's achieved |
|---|---|
| Zero manual secrets | GHCR with automatic `GITHUB_TOKEN` — no Docker Hub credentials needed |
| No third-party actions | Only `actions/checkout@v4`; `gh` CLI for workflow dispatch and releases |
| No QEMU | Native runners: `ubuntu-24.04` (amd64) and `ubuntu-24.04-arm` (arm64) |
| Single volume | All state under `/unifi` via symlinks in `entrypoint.sh` |
| DRY CI | `resolve-version` job fetches URLs once; build jobs consume outputs |

---

## Project Structure

```
.github/workflows/
  build.yml         # Multi-arch build + manifest + optional GitHub Release
  check-update.yml  # Daily version check; auto-bumps Dockerfile on new release
Dockerfile          # Thin overlay: labels, ARG/ENV version, entrypoint
entrypoint.sh       # Container init: volume symlinks, UUID, arch, systemd handoff
compose.yaml        # Reference deployment
```

---

## CI/CD Workflows

### `build.yml`

**Triggers:** push to `main`, tag `v*`, `workflow_dispatch` (optional version input).

**Job graph:**

```
resolve-version
    ├── build-amd64 ─┐
    └── build-arm64 ─┴── manifest
```

| Job | Runner | What it does |
|---|---|---|
| `resolve-version` | ubuntu-latest | Reads/validates version; fetches both installer URLs from Ubiquiti API |
| `build-amd64` | ubuntu-24.04 | Runs installer, extracts podman image, builds & pushes `:<version>-amd64` |
| `build-arm64` | ubuntu-24.04-arm | Same for arm64; pushes `:<version>-arm64` |
| `manifest` | ubuntu-latest | `docker buildx imagetools create` → `:<version>` + `:latest`; `gh release create` on tag |

**Images published to:** `ghcr.io/OWNER/unifi-os-server`

**No third-party actions used** — `gh` CLI handles workflow dispatch and GitHub Release creation.

### `check-update.yml`

**Triggers:** daily at 06:00 UTC, `workflow_dispatch`.

**Single job `check` steps:**
1. Read `ARG UOS_SERVER_VERSION` from `Dockerfile`.
2. Query `https://fw-update.ubnt.com/api/firmware-latest` (linux-x64, release channel).
3. If versions differ: `sed`-bump `Dockerfile`, `git commit + tag + push`, `gh workflow run build.yml`.

---

## Version Source of Truth

`ARG UOS_SERVER_VERSION=` in `Dockerfile`. Both workflows parse it with:

```bash
grep -oP '^ARG UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile
```

When bumping manually: update only this line. The `check-update.yml` job does this automatically.

---

## How the Base Image Is Extracted (CI)

The official Ubiquiti installer (`unifi-os-server`) installs `uosserver` as a
rootless Podman container under `/home/uosserver/`. The CI jobs:

1. Pre-create Podman storage config so the installer finds it.
2. Run `sudo ./unifi-os-server` — exits non-zero even on success when non-interactive, hence `|| true`.
3. Copy Podman storage layers to the runner user (`/home/runner/`).
4. `podman save | docker load` → `docker tag … uosserver-base:local`.
5. Build the thin overlay on top.

Disk space is freed before step 2 (`dotnet`, `android`, `ghc`, `CodeQL` toolchains).

---

## Entrypoint (`entrypoint.sh`)

Runs before systemd; performs in order:

| Step | Detail |
|---|---|
| Volume symlinks | Maps 8 internal paths to `/unifi/<subdir>` via associative array; seeds target on first run |
| UUID | Reads `UOS_UUID` env or auto-generates v5-style UUID; persists to `/unifi/data/uos_uuid` |
| Architecture | Detects `amd64`/`arm64` via `dpkg`; writes `/usr/lib/platform` |
| Version stamp | Writes `/usr/lib/version` from `UOS_SERVER_VERSION` env |
| Network alias | Creates `eth0` macvlan from `tap0` if eth0 absent (requires `NET_ADMIN` + `macvlan` module) |
| Service dirs | `mkdir + chown` for nginx, mongodb, rabbitmq log dirs |
| System IP | Upserts `system_ip=` in `/var/lib/unifi/system.properties` from `UOS_SYSTEM_IP` env |
| Handoff | `exec /sbin/init` — systemd takes over as PID 1 |

---

## Critical Runtime Requirements

Systemd is PID 1. Missing any of these causes the container to appear up but
run no services:

```yaml
cgroup: host                          # cgroupns=host — systemd needs cgroup v2 access
cap_add: [SYS_ADMIN, NET_ADMIN, ...]  # see compose.yaml for full list
tmpfs:
  - /run:exec                         # without :exec, systemd unit activations fail
  - /run/lock
  - /tmp:exec
  - /var/lib/journal
  - /var/opt/unifi/tmp:size=64m
volumes:
  - /sys/fs/cgroup:/sys/fs/cgroup:rw  # must be rw; ro causes cryptic failures
```

Host must use **cgroup v2**: `stat -fc %T /sys/fs/cgroup` → `cgroup2fs`.

Do **not** use `privileged: true` — the explicit capability list in `compose.yaml` is sufficient and more secure.

---

## Volume Layout

Single Docker volume at `/unifi`:

| Subdir | Internal path | Contents |
|---|---|---|
| `data/` | `/data` | Application data, `uos_uuid` |
| `db/` | `/var/lib/mongodb` | MongoDB data |
| `config/` | `/var/lib/unifi` | `system.properties` |
| `logs/` | `/var/log` | Service logs |
| `srv/` | `/srv` | Served files |
| `persistent/` | `/persistent` | Core UOS persistent state |
| `rabbitmq-ssl/` | `/etc/rabbitmq/ssl` | RabbitMQ TLS certificates |
| `app/` | `/usr/lib/unifi` | UniFi application files |

**Never mount this volume on two running containers simultaneously** — state will be corrupted.

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `UOS_SYSTEM_IP` | Yes | Hostname or IP reachable by UniFi devices for inform/adoption |
| `UOS_UUID` | No | Fixed controller UUID; auto-generated and persisted on first start if absent |

---

## Common Pitfalls

- **Missing `tmpfs` mounts** — Without `/run:exec`, systemd services fail silently; container appears healthy.
- **`/sys/fs/cgroup` not `rw`** — Read-only cgroup causes cryptic service startup failures.
- **cgroup v1 host** — Container will not start; cgroup v2 is mandatory.
- **GUI tools (Portainer, etc.)** — Often strip `tmpfs` and `cgroupns` silently. Deploy via `docker compose` or plain `docker run`.
- **Reinstalling UniFi Network** — The Network app ships inside the base image with ucore integration. Installing the standalone `.deb` from ui.com breaks the first-boot wizard with "unexpected error during setup".
- **Port 8080 mandatory** — Device communication/adoption fails without it. Port 11443 (→443) is the GUI. All other ports are optional.
- **`macvlan` kernel module** — Needed for the `eth0`-from-`tap0` alias step. Load on the host: `modprobe macvlan`.
