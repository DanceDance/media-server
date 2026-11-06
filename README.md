# Automated Home Media Server

A Docker Compose home media server stack for automated media requests, torrent downloading, library organization, and Direct Play streaming via Plex.

## Table of Contents

- [User Flow](#user-flow)
- [System Architecture](#system-architecture)
- [Deployment](#deployment)
- [Post-Setup (Machine-Specific Steps)](#post-setup-machine-specific-steps)
- [Service Configuration (Disaster Recovery / From Scratch)](#service-configuration-disaster-recovery--from-scratch)
- [References](#references)

---

## User Flow

1. A user requests a movie or TV show via **Seerr**.
2. **Seerr** forwards the request to **Radarr** (movies) or **Sonarr** (TV shows).
3. **Radarr** / **Sonarr** query indexers through **Prowlarr** (backed by **FlareSolverr** for Cloudflare-protected sites) and send matching releases to **qBittorrent**.
4. **qBittorrent** stages active downloads on the SSD (`TEMP_ROOT` -> `/data/incomplete`) and moves completed files to the HDD (`DATA_ROOT` -> `/data/downloads`).
5. **Radarr** / **Sonarr** atomically hardlink and rename finished files into `/data/media/movies` or `/data/media/tv`.
6. **Plex** detects the filesystem event (`inotify`) and updates the library for immediate streaming.

---

## System Architecture

![architecture](architecture.png "architecture")

| Service | Host Port | Internal Container URL | Role |
| :--- | :--- | :--- | :--- |
| **Plex** | `32400` | `http://plex:32400` | Media server and player |
| **Seerr** | `10500` | `http://seerr:5055` | Media discovery and request frontend |
| **Radarr** | `10501` | `http://radarr:7878` | Movie library and download manager |
| **Sonarr** | `10502` | `http://sonarr:8989` | TV show library and download manager |
| **Prowlarr** | `10503` | `http://prowlarr:9696` | Indexer manager synced to Radarr & Sonarr |
| **qBittorrent** | `10504` | `http://qbittorrent:10504` | Torrent download client |
| **Heimdall** | `10505` | `http://heimdall:80` | Web dashboard for service links |
| **FlareSolverr** | `10506` | `http://flaresolverr:8191` | Proxy server to bypass Cloudflare challenges |

> **Note:** Always use the **Internal Container URL** (service name + internal port) when connecting containers to each other, never the host's LAN IP.

---

## Deployment

### Storage Layout
The stack uses two host paths configured in `.env` (`DATA_ROOT` and `TEMP_ROOT`) plus `./provision` in the repository directory for container configs:

```text
${DATA_ROOT}/                  # Mounted as /data inside radarr, sonarr, qbittorrent
├── media/
│   ├── movies/                # Mounted at /data/media/movies in plex, radarr
│   └── tv/                    # Mounted at /data/media/tv in plex, sonarr
├── downloads/
│   ├── movies/                # qBittorrent 'radarr' category save path
│   └── tv/                    # qBittorrent 'sonarr' category save path
└── backup/                    # Weekly tar.gz backups of ./provision created by update_stack.sh

${TEMP_ROOT}/                  # Mounted as /data/incomplete in qbittorrent (SSD staging)
./provision/                   # Gitignored container configurations and databases
```

### Quick Start
1. **Start the stack:**
   ```bash
   ./start.sh
   ```
   Creates `.env` from `.env.defaults` (if missing), pulls images, and starts all containers.
2. **Enable weekly automated updates and backups:**
   ```bash
   ./setup_cron.sh
   ```
   Schedules [`update_stack.sh`](update_stack.sh) every Monday at `04:00 AM` (pulls images quietly, stops containers once, archives `./provision` to `${DATA_ROOT}/backup` keeping the last 2 backups, starts containers, and prunes dangling images).

---

## Post-Setup (Machine-Specific Steps)

Because `.env` and `./provision` are gitignored, apply these 4 machine-specific steps when migrating or deploying on a new host:

### 1. Mount Storage Drive (`/etc/fstab`)
Format the media drive as `ext4` and mount it with `noatime` (required for instant hardlinks and `inotify` library scans; see [`finished_plans/STORAGE_MIGRATION_EXT4.md`](finished_plans/STORAGE_MIGRATION_EXT4.md)):
```fstab
UUID=<DRIVE_UUID>  /mnt/storage  ext4  defaults,noatime  0  2
```

### 2. Set Host Paths in `.env`
Update `.env` with the host's storage and SSD scratch paths:
```ini
DATA_ROOT=/mnt/storage/MediaServer
TEMP_ROOT=/home/<user>/tmp/MediaServerTemp
```

### 3. Restore `./provision` Backup & Run Scripts
Restoring the latest backup from `${DATA_ROOT}/backup/` restores all service configurations, custom formats, categories, and API keys automatically:
```bash
tar -xzf /mnt/storage/MediaServer/backup/media-server-<LATEST>.tar.gz -C .
./start.sh
./setup_cron.sh
```

### 4. Update Machine-Specific LAN Settings in Plex
Because `plex` runs in a Docker bridge network (`172.18.0.0/16`), update these settings in **Plex -> Settings -> Network** (Show Advanced) or in `provision/plex/Library/Application Support/Plex Media Server/Preferences.xml` whenever the host IP or LAN subnet changes:

| Setting (UI / `Preferences.xml`) | Value | Purpose |
| :--- | :--- | :--- |
| **LAN Networks** (`LanNetworksBandwidth`) | `<YOUR_LAN_SUBNET>/24` | Prevents Docker bridge from treating local LAN streams as `WAN` (`local="0"`). |
| **Custom server access URLs** (`customConnections`) | `http://<YOUR_HOST_LAN_IP>:32400` | Publishes the host's real LAN IP to `plex.tv` instead of the internal `172.18.0.x` container IP. |
| **List of IP addresses and networks that are allowed without auth** (`allowedNetworks`) | `<YOUR_LAN_SUBNET>/255.255.255.0` | Allows local LAN devices to reach Plex without remote auth issues. |
| **Transcoder temporary directory** (`TranscoderTempDirectory`) | `/transcode` | Uses the 2 GB RAM `tmpfs` mount defined in `docker-compose.yml` (*Settings -> Transcoder*). |

---

## Service Configuration (Disaster Recovery / From Scratch)

> Restoring `media-server-*.tar.gz` in [Post-Setup Step 3](#3-restore-provision-backup--run-scripts) already configures all services below. Expand this section only if rebuilding from an empty `./provision` folder without a backup.

<details>
<summary><strong>Click to expand manual service setup settings</strong></summary>

### Plex (`http://<host>:32400/web`)
- Add libraries pointing to `/data/media/movies` and `/data/media/tv`.
- **Settings -> Library:** Enable **Scan my library automatically** and **Run a partial scan when changes are detected**.
- Apply the network and transcoder settings from [Post-Setup Step 4](#4-update-machine-specific-lan-settings-in-plex).

### Seerr (`http://<host>:10500`)
- **Settings -> Plex:** Hostname/IP `plex`, Port `32400`.
- **Settings -> Services:**
  - **Radarr:** Hostname `radarr`, Port `7878`, Profile `HD-1080p`, Root Folder `/data/media/movies`, Minimum Availability `Released`.
  - **Sonarr:** Hostname `sonarr`, Port `8989`, Profile `HD-1080p`, Root Folder `/data/media/tv`.

### qBittorrent (`http://<host>:10504`)
- **Options -> Downloads -> Saving Management:**
  - **Default Torrent Management Mode:** `Automatic`
  - **When Torrent Category / Default Save Path / Category Save Path changed:** `Relocate torrent` / `Relocate affected torrents`
  - **Default Save Path:** `/data/downloads`
  - **Keep incomplete torrents in:** Checked -> `/data/incomplete`
- **Categories:** `radarr` -> `/data/downloads/movies`, `sonarr` -> `/data/downloads/tv`
- **Options -> BitTorrent -> Seeding Limits:** Enable **When ratio reaches** `0` -> **Pause torrent**.

### Prowlarr (`http://<host>:10503`) & FlareSolverr
- **Settings -> Indexers -> Add -> FlareSolverr:** Host `http://flaresolverr:8191`, Timeout `60s`, Tag `flaresolverr`.
- **Settings -> Apps:**
  - **Radarr:** Prowlarr `http://prowlarr:9696`, Radarr `http://radarr:7878`, Sync Level `Full Sync`.
  - **Sonarr:** Prowlarr `http://prowlarr:9696`, Sonarr `http://sonarr:8989`, Sync Level `Full Sync`.

### Radarr (`http://<host>:10501`) & Sonarr (`http://<host>:10502`)
- **Settings -> Download Clients -> qBittorrent:** Host `qbittorrent`, Port `10504`, Category `radarr` / `sonarr`.
- **Settings -> Media Management:**
  - Enable **Use Hardlinks instead of Copy** (`copyUsingHardlinks: true`) and **Unmonitor Deleted Movies** (Radarr).
  - **Root Folders:** `/data/media/movies` (Radarr) and `/data/media/tv` (Sonarr).
  - **Radarr Naming:** Movie Folder `{Movie Title} ({Release Year})`, Standard Movie `{Movie Title} ({Release Year}) {Quality Full}`.
  - **Sonarr Naming:** Series Folder `{Series Title} {Series TitleYear}`, Season Folder `Season {season:00}`, Standard Episode `S{season:00}E{episode:00} - {Series Title} - {Episode Title} {Quality Full}`.
- **Settings -> Custom Formats & Profiles (`HD-1080p`):**
  - Score `x265` (HEVC non-Remux) at `+1000`, `HDR` at `-1000`, and `Language: Not Original` at `-10000`.

### Heimdall (`http://<host>:10505`)
- Add dashboard tiles for Plex (`:32400/web`), Seerr (`:10500`), Radarr (`:10501`), Sonarr (`:10502`), Prowlarr (`:10503`), and qBittorrent (`:10504`).

</details>

---

## References

- [Servarr Docker Guide](https://wiki.servarr.com/docker-guide)
- [TRaSH Guides (Radarr & Sonarr Custom Formats)](https://trash-guides.info/)
- [Original Upstream Inspiration - wiki.ayanev.eu](https://wiki.ayanev.eu/#/do-it-yourself/2023-01-home-media-server/)
