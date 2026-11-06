# Media Server Optimization Checklist

A living checklist tracking all identified fixes, optimizations, and architectural enhancements for the media server stack (`~/media-server`).

---

## Progress Overview

- **Phase 1: Critical Bug Fixes & Stability** `[ 4 / 5 ]`
- **Phase 2: Playback Performance & Indexer Health** `[ 1 / 2 ]`
- **Phase 3: Storage, Cleanup & I/O Optimization** `[ 2 / 5 ]`
- **Phase 4: Privacy & Network Security (Gluetun VPN)** `[ 0 / 4 ]`
- **Phase 5: Missing Services & Stack Expansion** `[ 0 / 5 ]`
- **Phase 6: Docker Best Practices & Long-Term Maintenance** `[ 1 / 5 ]`

---

## Phase 1: Critical Bug Fixes & Stability (Immediate)

- [x] **1.1 Fix Seerr ↔ Plex connection timeout**
  - **Issue**: Seerr logs `connect ETIMEDOUT 192.168.50.161:32400` every 5 minutes because of an old host IP.
  - **Action**: In `provision/overseerr/settings.json` (or via Seerr Web UI under *Settings -> Plex*), update `ip` from `192.168.50.161` to `plex` (Docker internal container DNS).
  - **Verification**: Run `docker logs --tail 20 seerr` and verify Plex library scan succeeds without timeout.

- [x] **1.2 Mount `/dev/shm:/transcode` for Plex**
  - **Issue**: Plex preferences specify `TranscoderTempDirectory="/transcode"`, but no `/transcode` volume is mounted in `docker-compose.yml`. Transcode chunks write into the root SSD container overlayfs.
  - **Action**: Add dedicated 2G tmpfs mount (`/transcode:size=2G,mode=0777`) to `plex` service.
  - **Verification**: Verified inside container with `df -h /transcode` (tmpfs 2.0G mounted, 0% used).

- [x] **1.3 Fix FlareSolverr runaway container storage leak (Reclaim 2.2 GB)**
  - **Issue**: FlareSolverr writable container layer has grown to **2.22 GB** due to accumulated Chromium `/tmp` cache and Widevine updates.
  - **Action**: Add `tmpfs: - /tmp:size=256M` and `mem_limit: 512m` to the `flaresolverr` service in `docker-compose.yml`. Recreate container with `docker compose up -d --force-recreate flaresolverr`.
  - **Verification**: Size dropped from 2.22 GB to 22.4 MB; tmpfs 256M active on `/tmp`; HTTP health check returned `"FlareSolverr is ready!"`.

- [ ] **1.4 Configure Plex connection webhooks in Radarr & Sonarr (Optional)**
  - **Context**: Now that `/mnt/storage` has been migrated to `ext4` and Plex has `FSEventLibraryUpdatesEnabled="1"` and `FSEventLibraryPartialScanEnabled="1"` enabled, Linux kernel `inotify` events work natively. Adding webhooks in Radarr/Sonarr is optional for explicit rename/import triggers.
  - **Action**: In Radarr & Sonarr, go to **Settings -> Connect -> Add (+) -> Plex Media Server**, set host to `plex`, port `32400`, enter token, and enable update on import/rename (or apply via API).
  - **Verification**: Test connection in Radarr/Sonarr settings and verify a green checkmark.

- [x] **1.5 Optimize `update_stack.sh` (Quiet Pulls, Single-Stop Backup Flow & Image Prune)**
  - **Issue**: `docker compose pull` lacked `--quiet` (filling `update.log` with 475 KB of progress bars), stopped/restarted containers twice per run, and left untagged `<none>` images behind after updates.
  - **Action**: Reordered `update_stack.sh` to run `docker compose pull --quiet` before stopping containers, perform a single stop/backup/start pass (`RETENTION=2`), run `docker image prune -f`, and truncated `update.log`.
  - **Verification**: Verified with `bash -n` and a full end-to-end run of `update_stack.sh`.

---

## Phase 2: Playback Performance & Indexer Health

- [x] **2.2 Configure Plex LAN Subnet (`LanNetworksBandwidth="192.168.50.0/24"`)**
  - **Issue**: Because Plex runs in a Docker bridge network (`172.18.0.0/16`) without `LanNetworksBandwidth` set, Plex classified all local `192.168.50.x` devices (including the Xiaomi TV Box S 3rd Gen `MiTV-AFMU0`) as `WAN` (`local="0"`).
  - **Action**: Set `LanNetworksBandwidth="192.168.50.0/24"` in Plex `Preferences.xml` (verified direct play of 1080p 10-bit HEVC + AAC 5.1 with zero transcoding).

- [ ] **2.5 Fix Broken Prowlarr Indexer Definitions & Rate-Limited Indexers**
  - **Issue**:
    1. **Active Error (`IndexerNoDefinitionCheck`)**: `RuTracker.RU` and `BitSearch` have missing/obsolete definitions and will not work until removed or re-added.
    2. **Long-Term Failures (`IndexerLongTermStatusCheck`)**: `1337x`, `ExtraTorrent.st`, `kickasstorrents.ws`, and `Uindex` are failing due to rate limits (429) or Cloudflare blocks.
  - **Action**: Remove broken `RuTracker.RU` and `BitSearch` entries in Prowlarr; clean up or assign FlareSolverr tags to the remaining failing indexers.
  - **Verification**: Check Prowlarr, Radarr, and Sonarr `/health` endpoints and verify zero indexer warnings/errors.

---

## Phase 3: Storage, Disk Cleanup & I/O Optimization

- [ ] **3.1 Clean up leftover temporary & archive files**
  - **Completed so far**: Deleted `/mnt/storage/Downloads/torrents/wind_and_truth.tar` (reclaimed 2.0 GB), unmonitored/deleted *Desperate Housewives* S1–S4 (reclaimed 59.1 GB), and replaced *LOTR* trilogy remuxes with 1080p HEVC Extended releases (reclaimed ~81 GB).
  - **Remaining Action**:
    - Delete the 2 leftover hidden `.parts` files in `/mnt/storage/MediaServer/media/movies/` and `tv/`.
    - Review and clean up `/mnt/storage/Downloads/torrents/Wind and Truth` (1.9 GB), `Downloads/torrents/MAM` (540 MB), and `Downloads/MAM_Points` (357 MB) if no longer needed.
  - **Verification**: Run `df -h /mnt/storage` and check freed disk space.

- [ ] **3.2 Configure Radarr & Sonarr automated cleanup (`deleteEmptyFolders` & Recycle Bin)**
  - **Issue**: Both Radarr and Sonarr have `deleteEmptyFolders: false` and no Recycle Bin configured (`recycleBin: ""`).
  - **Action**: Enable `deleteEmptyFolders: true` in Radarr & Sonarr **Media Management** settings, and optionally configure a Recycle Bin folder with auto-cleanup after 7 days.
  - **Verification**: Query `/api/v3/config/mediamanagement` in Radarr and Sonarr to confirm settings are active.

- [x] **3.3 `TEMP_ROOT` SSD Incomplete Downloads + `ext4` Hardlink Imports**
  - **Status**: Active incomplete downloads write to the SSD (`/home/kkgmig29/tmp/MediaServerTemp`) to prevent HDD thrashing, then move to `/mnt/storage/MediaServer/downloads` on completion. With `/mnt/storage` now on `ext4` and `copyUsingHardlinks: True` enabled in Radarr/Sonarr, imports from `downloads/` to `media/` use instant zero-copy hardlinks.

- [x] **3.4 Migrate `/mnt/storage` from NTFS (`ntfs3`) to `ext4`**
  - **Status**: Completed. `/dev/sda1` is formatted as `ext4` (`Storage`) and mounted at `/mnt/storage` with `defaults,noatime` in `/etc/fstab` (documented in `STORAGE_MIGRATION_EXT4.md`).

- [ ] **3.5 Configure Low-Disk-Space Notifications**
  - **Action**: Set up notification alerts in Seerr/Radarr/Sonarr (via Telegram, Pushbullet, or Discord) when available disk space falls below 50 GB.

---

## Phase 4: Privacy & Network Security (Gluetun VPN)

- [ ] **4.1 Add Gluetun VPN container to `docker-compose.yml`**
  - **Action**: Add `qmcgaw/gluetun` service configured for your VPN provider (e.g. ProtonVPN, Mullvad, AirVPN) with WireGuard or OpenVPN.
  - **Verification**: Start Gluetun and verify successful connection in `docker logs gluetun`.

- [ ] **4.2 Route qBittorrent network through Gluetun**
  - **Action**:
    - Attach `network_mode: "service:gluetun"` to `qbittorrent`.
    - Move qBittorrent ports (`10504:10504` and torrent listen port) to the `gluetun` container service definition.
    - Remove exposed ports from `qbittorrent`.
  - **Verification**: Access qBittorrent Web UI at `http://localhost:10504`.

- [ ] **4.3 Confirm qBittorrent IP & Killswitch**
  - **Action**: Execute `docker exec gluetun curl -s ifconfig.me` and check against public host IP.
  - **Verification**: Verify IP matches the VPN gateway, not your home ISP.

- [ ] **4.4 Update Radarr & Sonarr Download Client connection**
  - **Action**: Ensure Radarr and Sonarr can still communicate with qBittorrent (host: `gluetun` or `localhost`, port: `10504`).
  - **Verification**: Test Download Client connection in Radarr and Sonarr.

---

## Phase 5: Missing Services & Stack Expansion

- [ ] **5.1 Add Bazarr for automated subtitle management**
  - **Issue**: Bazarr is documented in `README.md` and `.gitignore` but missing from `docker-compose.yml`.
  - **Action**: Add `lscr.io/linuxserver/bazarr:latest` to `docker-compose.yml` mapped to movies and TV folders on port `10507:6767`.
  - **Verification**: Access Bazarr at port `10507`, connect Radarr and Sonarr, and test subtitle retrieval.

- [ ] **5.2 Add Audiobookshelf for audiobook streaming**
  - **Context**: You already have an audiobooks library (`/mnt/storage/MediaServer/media/audiobooks`) with *The Expanse* and *Red Rising*.
  - **Action**: Add `ghcr.io/advplyr/audiobookshelf:latest` mapped to the audiobooks directory on port `10509:80`.
  - **Verification**: Access web interface at port `10509`, create audiobooks library, and test playback from browser or mobile app.

- [ ] **5.3 Upgrade Dashboard (Homepage or Homarr)**
  - **Context**: Heimdall provides static links; modern dashboards like **Homepage** provide real-time widgets (Plex streams, download speeds, disk space, upcoming releases).
  - **Action**: (Optional) Add Homepage container with service widgets configured.

- [ ] **5.4 Add Tautulli for Plex Analytics & Monitoring (Optional)**
  - **Action**: Add `lscr.io/linuxserver/tautulli` to track playback statistics, bandwidth usage, and user stream history.

- [ ] **5.5 Reorganize port allocations in documentation**
  - **Action**: Ensure all new services follow your sequential port mapping pattern (`10500` through `10510`).

---

## Phase 6: Docker Best Practices & Hygiene

- [ ] **6.1 Add Docker container logging limits**
  - **Action**: Add default logging configuration (`max-size: "10m"`, `max-file: "3"`) across all services in `docker-compose.yml`.
  - **Verification**: Verify JSON log file sizes in `/var/lib/docker/containers/` are capped.

- [x] **6.2 Prune dangling Docker images (Reclaimed 6.41 GB on SSD)**
  - **Status**: Completed via `docker image prune -f` in `update_stack.sh`, reclaiming 6.41 GB of old untagged image layers.

- [ ] **6.3 Standardize `.env` variable usage**
  - **Action**: Replace hardcoded values (`TZ=Asia/Taipei`, `PLEX_UID=1000`) in `docker-compose.yml` with `${TZ}`, `${PUID}`, `${PGID}` from `.env`.

- [ ] **6.4 Define container memory limits for utility services**
  - **Completed so far**: Added `mem_limit: 512m` to `flaresolverr`.
  - **Remaining Action**: Add `mem_limit: 256m` to `heimdall` in `docker-compose.yml` to cap utility service RAM usage.

- [ ] **6.5 Remove stray Node.js files from repository root**
  - **Issue**: Empty/unused `package.json` (3 bytes) and `package-lock.json` (91 bytes) exist in `~/media-server`.
  - **Action**: Delete `package.json` and `package-lock.json` from `~/media-server`.
