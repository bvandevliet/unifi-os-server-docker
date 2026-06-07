# AGENTS.md — unifi-os-server-docker

AI agent guide for this project: a minimal, auto-updating Docker image that
repackages the official Ubiquiti UniFi OS Server binary for standard container
infrastructure with multi-arch support (amd64/arm64).

---

## Design Goals

| Goal | How it's achieved |
|---|---|
| Zero manual secrets | GHCR with automatic `GITHUB_TOKEN` — no Docker Hub credentials needed |
| No third-party actions | Only `actions/checkout@v4`; `gh` CLI for releases and git ops |
| Native runners | `ubuntu-24.04` (amd64) and `ubuntu-24.04-arm` (arm64) via matrix — no QEMU |
| Single volume | All state under `/unifi` via symlinks in `entrypoint.sh` |
| DRY CI | Matrix strategy deduplicates the two arch build jobs into one job definition |
| Decoupled scripts | All CI logic lives in `.github/scripts/`; each script is runnable standalone |

---

## Project Structure

```
.github/
  workflows/
    build.yml         # Multi-arch matrix build + manifest + optional GitHub Release
    check-update.yml  # Daily version check; auto-bumps Dockerfile on new release
  scripts/
    resolve-version.sh  # Resolve version + GHCR image name; fetch installer URL
    install-uos.sh      # Free disk space + download + run Ubiquiti installer
    load-base-image.sh  # Copy Podman storage to Docker via skopeo
    build-push.sh       # docker build + docker push for one arch
    create-manifest.sh  # docker buildx imagetools create (multi-arch manifest)
    check-update.sh     # Version check, Dockerfile bump, commit + tag + push
Dockerfile          # Thin overlay: labels, ARG/ENV version, entrypoint
entrypoint.sh       # Container init: volume symlinks, UUID, arch, systemd handoff
compose.yaml        # Reference deployment
```

---

## CI/CD Workflows

### `build.yml`

**Triggers:** tag push `v*` (from `check-update.yml`) and `workflow_dispatch`.
`workflow_dispatch` exposes two inputs:
- `version` — override the version resolved from the Dockerfile (optional)
- `dry_run` — skip push/manifest/release; validates the extraction pipeline only (boolean)

**Job graph:**

```
build (matrix: amd64 ‖ arm64)
    └── manifest
```

| Job | Runner | What it does |
|---|---|---|
| `build` (amd64 leg) | ubuntu-24.04 | Resolves version + URL, runs installer, extracts image, builds & pushes `:<version>-amd64` |
| `build` (arm64 leg) | ubuntu-24.04-arm | Same for arm64; pushes `:<version>-arm64` |
| `manifest` | ubuntu-latest | `docker buildx imagetools create` → `:<version>` + `:latest`; `gh release create` on tag |

`fail-fast: false` is set on the matrix so a failure in one arch leg does not cancel the other.

`manifest` is skipped entirely when `dry_run` is set (`if: ${{ !inputs.dry_run }}`).

**Images published to:** `ghcr.io/OWNER/unifi-os-server`

**Permissions:**
- `build` job: `contents: read` (checkout) + `packages: write` (GHCR push)
- `manifest` job: `contents: write` (gh release) + `packages: write` (GHCR push)

> **Private repo note:** `ubuntu-24.04-arm` is a GitHub larger runner available on GitHub Team
> or for public repos on free accounts. On a private repo with a free account the workflow will
> appear to not exist in the Actions tab (GitHub silently refuses to parse it).

### `check-update.yml`

**Triggers:** daily at 06:00 UTC, `workflow_dispatch`.

**Single job `check`:**
1. Read `ARG UOS_SERVER_VERSION` from `Dockerfile`.
2. Query Ubiquiti API (`linux-x64`, release channel).
3. If versions differ: `sed`-bump `Dockerfile`, `git commit + tag + push`.
4. Tag push to `v*` automatically triggers `build.yml` — no explicit dispatch needed.

---

## Version Source of Truth

`ARG UOS_SERVER_VERSION=` in `Dockerfile`. All scripts parse it with:

```bash
grep -oP '^ARG UOS_SERVER_VERSION=\K[0-9.]+' Dockerfile
```

When bumping manually: update only this line. `check-update.yml` does this automatically.

---

## Scripts (Standalone Usage)

All scripts are fully decoupled from GitHub Actions — no hardcoded `GITHUB_*` variables.
`GITHUB_OUTPUT` is written only when that variable is set in the environment.

```bash
# Resolve version + image name from Dockerfile (no arch URL)
bash .github/scripts/resolve-version.sh

# Resolve version + image + download URL for a specific arch
ARCH_PLATFORM=linux-x64 bash .github/scripts/resolve-version.sh

# Check for updates (dry-run safe; only pushes when version differs)
GH_TOKEN=ghp_... bash .github/scripts/check-update.sh
```

---

## How the Base Image Is Extracted (CI)

The official Ubiquiti installer (`unifi-os-server`) installs `uosserver` as a
rootless Podman container under `/home/uosserver/`. The CI pipeline:

1. **Pre-create Podman storage config** (`install-uos.sh`):
   ```bash
   mkdir -p "$HOME/.config/containers"
   chmod 755 "$HOME" "$HOME/.config" "$HOME/.config/containers"
   touch "$HOME/.config/containers/storage.conf"
   chmod 644 "$HOME/.config/containers/storage.conf"
   ```
   **Why:** The installer's Podman subprocess runs as the `uosserver` user and stats
   `$HOME/.config/containers/storage.conf`. The runner's `$HOME` is mode `750` by default —
   `uosserver` cannot traverse it, causing a `permission denied` broken pipe that aborts the
   image load. `chmod 755` on the full path chain is required before running the installer.

2. **Run the installer** — exits non-zero even on success when non-interactive, hence `|| true`.
   The image is loaded into Podman storage at this point.

3. **Post-install container start** — the installer tries to start the container via `pasta`
   (user-mode networking). The system `pasta` on `ubuntu-24.04` may not support all flags
   used by the installer (e.g. `--map-host-loopback`), causing the start to fail. This is
   **harmless** — the image is already in Podman storage before the start attempt.
   The installer waits up to 60s for the container to become healthy before exiting.

4. **Copy Podman storage** (`load-base-image.sh`) — copies overlay dirs from
   `/home/uosserver/` to `$HOME` using `sudo`, then `chown`s them back to the runner user.

5. **Load into Docker** via `podman save IMAGE | docker load` + `docker tag` —
   `skopeo copy containers-storage:` requires user namespace support (`unshare`)
   which GitHub runners do not permit, so the tar-based approach is used instead.

6. **Build the thin overlay** — `docker build` using `uosserver-base:local` as base.

Disk space is freed before the download (`dotnet`, `android`, `ghc`, `CodeQL` toolchains).

### Known Issue: `pasta` version mismatch

The system `pasta` on `ubuntu-24.04` runners may not support all flags emitted by the
installer's `podman run` invocation (specifically `--map-host-loopback`). This causes the
post-install container start to fail with exit code 1 and a 60-second health wait timeout.

**Impact:** ~60s added to each build leg. Image extraction is unaffected.

**Fix (if needed):** Install a newer `passt` before running the installer. The `ppa:sejug/podman`
PPA packages the latest upstream `passt` for Ubuntu Noble, but it is a third-party PPA.
Alternatively, wait for Ubiquiti to ship a version of the installer that uses a flag set
compatible with the system `pasta`.

---

## Entrypoint (`entrypoint.sh`)

Runs as PID 1 before handing off to systemd; performs in order:

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

## What the Extracted Image Contains

The `uosserver` Podman image extracted from the installer is the **full UniFi OS Server stack**:
- UniFi OS platform layer
- UniFi Network application
- MongoDB, RabbitMQ, nginx
- All bundled services, managed by internal systemd units

Do **not** add MongoDB, RabbitMQ, or nginx as separate Compose services — they are already
running inside the container. The single `unifi_data:/unifi` volume captures all persistent
state for all internal services via symlinks set up by `entrypoint.sh`.

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

- **Private repo on free GitHub account** — `ubuntu-24.04-arm` is a larger runner, only available
  for public repos or GitHub Team+. The workflow will silently not appear in the Actions tab.
  Solution: make the repo public, or upgrade to GitHub Team.
- **Explicit job permissions drop `contents: read`** — When any permission is declared on a job,
  all others default to `none`. Always include `contents: read` on jobs that use `actions/checkout`.
- **Missing `tmpfs` mounts** — Without `/run:exec`, systemd services fail silently; container appears healthy.
- **`/sys/fs/cgroup` not `rw`** — Read-only cgroup causes cryptic service startup failures.
- **cgroup v1 host** — Container will not start; cgroup v2 is mandatory.
- **GUI tools (Portainer, etc.)** — Often strip `tmpfs` and `cgroupns` silently. Deploy via `docker compose` or plain `docker run`.
- **Reinstalling UniFi Network** — The Network app ships inside the base image with ucore integration. Installing the standalone `.deb` from ui.com breaks the first-boot wizard with "unexpected error during setup".
- **Port 8080 mandatory** — Device communication/adoption fails without it. Port 11443 (→443) is the GUI. All other ports are optional.
- **`macvlan` kernel module** — Needed for the `eth0`-from-`tap0` alias step. Load on the host: `modprobe macvlan`.

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
