# Media Server Optimization Checklist

A living checklist tracking all identified fixes, optimizations, and architectural enhancements for the media server stack (`~/media-server`).

---

## Progress Overview

- **Phase 1: Critical Bug Fixes & Stability** `[ 4 / 5 ]`
- **Phase 2: Playback Performance & Indexer Health** `[ 2 / 2 ]`
- **Phase 3: Storage, Cleanup & I/O Optimization** `[ 5 / 5 ]`
- **Phase 5: Missing Services & Stack Expansion (Optional)** `[ 1 / 2 ]`
- **Phase 6: Docker Best Practices & Long-Term Maintenance** `[ 5 / 5 ]`

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

- [x] **2.5 Fix Broken Prowlarr Indexer Definitions & Rate-Limited Indexers**
  - **Issue**: `RuTracker.RU` and `BitSearch` had missing/obsolete definitions (`IndexerNoDefinitionCheck`), and `1337x`, `ExtraTorrent.st`, `kickasstorrents.ws`, and `Uindex` had been failing for months (`IndexerLongTermStatusCheck`).
  - **Action**: Removed the 6 broken indexers, added and verified 4 working trackers (`EZTV`, `YTS`, `LimeTorrents`, `Nyaa.si`) alongside `Knaben`, `The Pirate Bay`, and `TorrentDownload` (7 active indexers total), and synced to Radarr and Sonarr.
  - **Verification**: Verified Prowlarr, Radarr, and Sonarr `/health` endpoints report zero warnings/errors.

---

## Phase 3: Storage, Disk Cleanup & I/O Optimization

- [x] **3.1 Clean up leftover temporary & archive files (Reclaimed ~142 GB)**
  - **Status**: Completed. Deleted `/mnt/storage/Downloads/torrents/wind_and_truth.tar` (2.0 GB), unmonitored/deleted *Desperate Housewives* S1–S4 (59.1 GB), and replaced *LOTR* trilogy remuxes with 1080p HEVC Extended releases (~81 GB). Left `/mnt/storage/Downloads` intact as those torrents are actively seeding.

- [x] **3.2 Configure Radarr & Sonarr automated cleanup (`deleteEmptyFolders`)**
  - **Status**: Completed. Enabled `deleteEmptyFolders: true` in both Radarr and Sonarr via `/api/v3/config/mediamanagement`.

- [x] **3.3 `TEMP_ROOT` SSD Incomplete Downloads + `ext4` Hardlink Imports**
  - **Status**: Active incomplete downloads write to the SSD (`/home/kkgmig29/tmp/MediaServerTemp`) to prevent HDD thrashing, then move to `/mnt/storage/MediaServer/downloads` on completion. With `/mnt/storage` now on `ext4` and `copyUsingHardlinks: True` enabled in Radarr/Sonarr, imports from `downloads/` to `media/` use instant zero-copy hardlinks.

- [x] **3.4 Migrate `/mnt/storage` from NTFS (`ntfs3`) to `ext4`**
  - **Status**: Completed. `/dev/sda1` is formatted as `ext4` (`Storage`) and mounted at `/mnt/storage` with `defaults,noatime` in `/etc/fstab` (documented in `finished_plans/STORAGE_MIGRATION_EXT4.md`).

- [x] **3.5 Configure Low-Disk-Space Notifications**
  - **Status**: Already active via host **Monit** (`monit.service`) in `/etc/monit/conf.d/diskcheck` (`space usage > 95%` on `/mnt/storage`), `/etc/monit/conf.d/cputemp` (`> 80°C`), and `/etc/monit/conf.d/hostalerts` (`swap usage > 60%`), which send Telegram alerts via `~/.bin/telegram_notify.sh`.

---

## Phase 5: Missing Services & Stack Expansion (Optional)

- [ ] **5.1 Add Maintainerr for automated media lifecycle & cleanup (Future / Someday)**
  - **Context**: Maintainerr connects to Plex, Seerr, Radarr, and Sonarr to automatically unmonitor and delete watched or stale movies/shows after a configurable retention period.
  - **Action**: Add `ghcr.io/jorenn92/maintainerr:latest` to `docker-compose.yml` (e.g. on port `10507:6246`) and configure cleanup rules when needed.

- [x] **5.5 Reorganize port allocations in documentation**
  - **Status**: Completed in `README.md` (`32400` and sequential `10500–10506` port table).

---

## Phase 6: Docker Best Practices & Hygiene

- [x] **6.1 Add Docker container logging limits**
  - **Status**: Completed. Added `x-logging` YAML anchor (`max-size: "10m"`, `max-file: "3"`) across all 8 services in `docker-compose.yml`.

- [x] **6.2 Prune dangling Docker images (Reclaimed 6.41 GB on SSD)**
  - **Status**: Completed via `docker image prune -f` in `update_stack.sh`, reclaiming 6.41 GB of old untagged image layers.

- [x] **6.3 Standardize `.env` variable usage**
  - **Status**: Completed. Replaced hardcoded `TZ=Asia/Taipei`, `PLEX_UID=1000`, `PLEX_GID=1000` in `docker-compose.yml` with `${TZ}`, `${PUID}`, `${PGID}` from `.env`.

- [x] **6.4 Define container memory limits for utility services**
  - **Status**: Completed. Added `mem_limit: 512m` to `flaresolverr` and `mem_limit: 256m` to `heimdall` in `docker-compose.yml`.

- [x] **6.5 Remove stray Node.js files from repository root**
  - **Status**: Completed. Removed unused `package.json` and `package-lock.json` from `~/media-server`.
