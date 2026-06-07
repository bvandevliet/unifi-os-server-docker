# UniFi OS Server — Docker

[![Build](https://github.com/bvandevliet/unifi-os-server-docker/actions/workflows/build.yml/badge.svg)](https://github.com/bvandevliet/unifi-os-server-docker/actions/workflows/build.yml)
[![GHCR](https://ghcr-badge.egpl.dev/bvandevliet/unifi-os-server/latest_tag?trim=major&label=ghcr.io&color=blue)](https://github.com/bvandevliet/unifi-os-server-docker/pkgs/container/unifi-os-server)

Run [UniFi OS Server](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi) in Docker — the new standard for self-hosted UniFi, replacing the legacy UniFi Network Application.

> UniFi OS Server delivers the same management experience as UniFi-native hardware (CloudKeys, Cloud Gateways, Official UniFi Hosting) and is fully compatible with Site Manager for centralized multi-site control. It supports features the legacy Network Application lacks: Organizations, IdP Integration, and Site Magic SD-WAN.
>
> — [Ubiquiti: Self-Hosting UniFi](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi)

**Features:**

- Built directly from the official Ubiquiti installer — no third-party base image
- Full UniFi OS stack: Network app, MongoDB, RabbitMQ, nginx — all bundled
- Single volume for all persistent data (database, config, logs)
- No `privileged: true` — uses an explicit, minimal capability set
- Multi-arch: `linux/amd64` and `linux/arm64` — native runners, no QEMU
- Auto-updated daily from official Ubiquiti releases via GitHub Actions

---

## Requirements

- Docker with **cgroup v2** on the host — verify with:
  ```bash
  stat -fc %T /sys/fs/cgroup   # must print: cgroup2fs
  ```
- Linux host (bare metal, VM, or WSL2 with systemd). Windows/macOS Docker Desktop is not supported.

---

## Quick Start

### Docker Compose (recommended)

```bash
# 1. Copy the compose file
curl -O https://raw.githubusercontent.com/bvandevliet/unifi-os-server-docker/main/compose.yaml

# 2. Set your server's hostname or IP (used by devices for adoption)
export UOS_SYSTEM_IP=192.168.1.10   # replace with your actual IP or hostname

# 3. Start
docker compose up -d
```

Then open **`https://<UOS_SYSTEM_IP>:11443`** to complete the setup wizard.

### Docker Run

```bash
docker run -d \
  --name unifi-os-server \
  --restart unless-stopped \
  --cgroup-ns host \
  --cap-drop ALL \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add NET_RAW \
  --cap-add NET_BIND_SERVICE --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH \
  --cap-add FOWNER --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --cap-add KILL --cap-add SYS_CHROOT --cap-add SYS_PTRACE \
  --cap-add SYS_RESOURCE --cap-add AUDIT_WRITE --cap-add MKNOD \
  --tmpfs /run:exec --tmpfs /run/lock --tmpfs /tmp:exec \
  --tmpfs /var/lib/journal --tmpfs /var/opt/unifi/tmp:size=64m \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v unifi_data:/unifi \
  -e UOS_SYSTEM_IP=192.168.1.10 \
  -p 11443:443 \
  -p 8080:8080 \
  -p 3478:3478/udp \
  -p 10003:10003/udp \
  ghcr.io/bvandevliet/unifi-os-server:latest
```

> **⚠️ All flags are required.** The container runs systemd as PID 1.
> Dropping any of the `tmpfs` mounts, `--cgroup-ns host`, or the capability list
> will result in the container appearing healthy while **no services start**.
> See [Troubleshooting](#troubleshooting).
>
> **Avoid GUI tools** (Portainer, Dockge, Coolify, etc.) — they frequently strip
> `tmpfs` and `cgroupns` silently. Use `docker compose` or plain `docker run`.

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `UOS_SYSTEM_IP` | **Yes** | Hostname or IP reachable by UniFi devices for adoption |
| `UOS_UUID` | No | Fixed controller UUID — auto-generated and persisted if not set |

---

## Ports

| Port | Protocol | Required | Description |
|---|---|---|---|
| 11443 | TCP | ✅ | Web GUI / API (maps container port 443) |
| 8080 | TCP | ✅ | Device communication and adoption (inform) |
| 3478 | UDP | ✅ | STUN |
| 10003 | UDP | ✅ | Device discovery |
| 8444 | TCP | Optional | Hotspot portal (HTTPS) |
| 6789 | TCP | Optional | Mobile speed test |
| 9543 | TCP | Optional | UniFi Identity Hub |
| 11084 | TCP | Optional | Site Supervisor |
| 5671 | TCP | Optional | AMQPS (RabbitMQ TLS) |
| 5514 | UDP | Optional | Remote syslog |
| 8880–8882 | TCP | Optional | Hotspot redirect (HTTP) |

---

## Data Persistence

All state is stored in a single Docker volume (`unifi_data`) mounted at `/unifi`.
The entrypoint maps internal paths to subdirectories via symlinks:

| Subdirectory | Internal path | Contents |
|---|---|---|
| `data/` | `/data` | Application data, controller UUID |
| `db/` | `/var/lib/mongodb` | MongoDB data files |
| `config/` | `/var/lib/unifi` | `system.properties` and configuration |
| `logs/` | `/var/log` | All service logs |
| `srv/` | `/srv` | Served files |
| `persistent/` | `/persistent` | Core UOS persistent state |
| `rabbitmq-ssl/` | `/etc/rabbitmq/ssl` | RabbitMQ TLS certificates |
| `app/` | `/usr/lib/unifi` | UniFi application files |

To use a bind mount instead of a named volume, replace `unifi_data:/unifi` with `/path/to/data:/unifi` and remove the `volumes:` section from `compose.yaml`.

> **Never mount this volume on two running containers simultaneously** — state will be corrupted.

---

## Device Adoption

For devices that aren't auto-discovered, set the inform URL manually over SSH:

```bash
# SSH into the device (default credentials: ubnt / ubnt)
ssh ubnt@<device-ip>

# Set the inform address
set-inform http://<UOS_SYSTEM_IP>:8080/inform
```

---

## Migrating from the UniFi Network Application

The UniFi Network Application (self-hosted `.deb`/`.jar`) is being deprecated in favour of UniFi OS Server. To migrate:

> **Official reference:** [Ubiquiti — Backups and Migration in UniFi](https://help.ui.com/hc/en-us/articles/360008976393)

### 1. Export your site

While the old Network Application is **still running**:

- Go to **Settings → System → Site Management → Export Site**
- Download the site export file and keep the guided walkthrough open in the browser — you'll need it in step 4

### 2. Start UniFi OS Server and complete the setup wizard

Follow the [Quick Start](#quick-start) above. Complete the setup wizard at `https://<UOS_SYSTEM_IP>:11443` — create a new installation.

### 3. Import the site in UOS

Open the **site switcher** in UOS (top-left of the Network UI, where the site name is shown; if not visible, first enable **Settings → System → Site Management → Multi-Site Management**) → **Import Site** → upload the site export file from step 1.

### 4. Complete the guided walkthrough in the old Network Application

Back in the old Network Application's guided walkthrough, enter the inform URL of UOS (`http://<UOS_SYSTEM_IP>:8080/inform`) and follow the remaining prompts.

> **Tip:** if you kept the same host IP and inform port mapping as the old Network Application, devices will reconnect to UOS automatically without any manual intervention.

### 5. Stop and decommission the old Network Application

Once all devices appear online in UOS, shut down the old Network Application.

### 6. Re-adopt devices (if needed)

If any device shows as offline or "Managed by Another Console" after the migration:

```bash
# SSH into the device and re-set the inform URL
set-inform http://<UOS_SYSTEM_IP>:8080/inform
```

As a last resort, [factory reset](https://help.ui.com/hc/en-us/articles/205143490) the device and re-adopt it.

> **Note:** Captive portal traffic moves from port 8843 (Network Application) to port **8444** (UniFi OS Server).

---

## Updates

Images are built and published automatically every day by GitHub Actions. To update:

```bash
docker compose pull && docker compose up -d
```

Version tags follow the official Ubiquiti release versions (e.g. `5.1.15`). The `latest` tag always points to the most recent stable release.

---

## Troubleshooting

### Container stays up but no services start

systemd (PID 1) failed to boot. Diagnose with:

```bash
docker exec unifi-os-server systemctl is-system-running
```

- **`offline`** — a required flag is missing. Most commonly:
  - `/run` is not a tmpfs — verify: `docker exec unifi-os-server sh -c "mount | grep ' /run '"`
  - `--cgroup-ns host` is not set
  - `/sys/fs/cgroup` mount is missing or read-only
  - Deployed via a GUI tool that silently stripped flags — recreate with `docker compose` or `docker run`
- **`degraded`** — this is **normal**. A few systemd units (`systemd-journald`, `logind`, `dev-hugepages.mount`) always fail under Docker; UniFi OS works regardless.

### Host must use cgroup v2

```bash
stat -fc %T /sys/fs/cgroup   # must print: cgroup2fs
```

If it prints `tmpfs`, your host uses cgroup v1 and the container will not start.

### "An unexpected error occurred during setup"

Do not install the standalone UniFi Network `.deb` from ui.com inside the container. The Network application already ships inside the base image with full ucore integration. Installing over it removes the integration the setup wizard requires.

### macvlan (optional — container on its own LAN IP)

To give the container a dedicated IP on your LAN (no port mapping required):

```bash
docker network create -d macvlan \
  --subnet 192.168.1.0/24 --gateway 192.168.1.1 \
  -o parent=eth0 unifi_net

docker run -d \
  --name unifi-os-server \
  --network unifi_net --ip 192.168.1.50 \
  -e UOS_SYSTEM_IP=192.168.1.50 \
  # ... all other flags as above, without -p ...
  ghcr.io/bvandevliet/unifi-os-server:latest
```

Access the GUI at `https://192.168.1.50` (port 443 directly, no `:11443`).

> The Docker host itself cannot reach the container via the macvlan IP — access it from another machine on the LAN.

---

## How It Works

1. The official Ubiquiti installer embeds the full `uosserver` OCI image (MongoDB, RabbitMQ, nginx, UniFi Network — all bundled, managed by internal systemd units)
2. GitHub Actions downloads the installer for each architecture, extracts the embedded Podman image, and converts it to Docker format via `podman save | docker load`
3. A thin Dockerfile layers an entrypoint script on top that handles volume symlinks, UUID persistence, architecture detection, and hands off to systemd as PID 1
4. Images are published to GHCR daily with automatic version detection from the Ubiquiti firmware API

---

## License

[MIT](LICENSE) — this project is not affiliated with or endorsed by Ubiquiti Inc.
