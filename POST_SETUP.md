# Post-Setup Checklist (Machine-Specific)

`./start.sh` initializes `.env` and starts the containers, `./setup_cron.sh` registers the weekly backup/update cron job, and `${DATA_ROOT}/backup/` holds full `./provision` backups of all service configs.

When deploying or migrating to a new machine, only the following **machine-specific** items need to be configured manually:

---

### 1. Mount Storage Drive (`/etc/fstab`)
Mount the `ext4` media drive with `noatime` (required for atomic hardlinks and instant `inotify` library scans; see [`finished_plans/STORAGE_MIGRATION_EXT4.md`](finished_plans/STORAGE_MIGRATION_EXT4.md)):
```fstab
UUID=<DRIVE_UUID>  /mnt/storage  ext4  defaults,noatime  0  2
```

### 2. Set Host Paths in `.env`
Before (or right after) running `./start.sh`, update `.env` with the machine's paths:
- `DATA_ROOT=/mnt/storage/MediaServer` (HDD storage for `media/`, `downloads/`, `backup/`)
- `TEMP_ROOT=/home/<user>/tmp/MediaServerTemp` (SSD scratch folder for incomplete downloads)

### 3. Restore `./provision` (If Migrating) & Enable Weekly Cron
```bash
# Optional: restore existing service configs from storage drive backup
tar -xzf /mnt/storage/MediaServer/backup/media-server-<LATEST>.tar.gz -C .

# Start stack and schedule weekly Monday 04:00 update + backup
./start.sh
./setup_cron.sh
```

### 4. Update Machine-Specific LAN Settings in Plex
Because `plex` runs in a Docker bridge network (`172.18.0.0/16`), update these three network settings in **Plex -> Settings -> Network** (Show Advanced) or in `provision/plex/Library/Application Support/Plex Media Server/Preferences.xml` whenever the host IP or LAN subnet changes:

| Setting (UI / `Preferences.xml`) | Value | Why It Is Needed |
| :--- | :--- | :--- |
| **LAN Networks** (`LanNetworksBandwidth`) | `<YOUR_LAN_SUBNET>/24` | Prevents Docker bridge from treating local LAN streams as `WAN` (`local="0"`). |
| **Custom server access URLs** (`customConnections`) | `http://<YOUR_HOST_LAN_IP>:32400` | Publishes the host's real LAN IP to `plex.tv` instead of the internal `172.18.0.x` container IP. |
| **List of IP addresses and networks that are allowed without auth** (`allowedNetworks`) | `<YOUR_LAN_SUBNET>/255.255.255.0` | Allows local LAN devices to reach Plex without remote auth issues. |
| **Transcoder temporary directory** (`TranscoderTempDirectory`) | `/transcode` | Uses the 2 GB RAM `tmpfs` mount from `docker-compose.yml` (under *Settings -> Transcoder*). |
