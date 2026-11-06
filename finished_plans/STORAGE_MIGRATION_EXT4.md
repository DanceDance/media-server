# Storage Migration Plan: NTFS to ext4

This plan migrates `/mnt/storage` from NTFS to ext4. Formatting `/dev/sda1` permanently erases it, so do not proceed until the independent Windows backup has been copied and verified. Keep that backup unchanged until the restored data and services have been checked.

## Current Environment Summary

| Component | Value | Notes |
| :--- | :--- | :--- |
| **Media Server IP** | `192.168.50.32` | Linux server running Docker media stack |
| **Media Disk** | `/dev/sda1` | Currently NTFS, mounted at `/mnt/storage` |
| **Used Storage** | **~442 GB** | Total capacity ~699 GB (~258 GB free) |
| **Windows PC** | `192.168.50.161` (`MIG29-PC`) | Backup host with free disk space on `D:` |
| **Backup Path** | `D:\MediaBackup` | Local folder on Windows PC |
| **Network Link** | LAN (1 Gbps) | Actual transfer speed and duration vary |

## Phase 0: Preflight

On the Linux server, confirm the source partition and mount point before starting. These commands are read-only:

```bash
lsblk -f
findmnt /mnt/storage
df -hT /mnt/storage
```

Confirm `/mnt/storage` is the intended NTFS filesystem on `/dev/sda1`, and record its current UUID and the exact contents to preserve. Verify the Samba share `\\192.168.50.32\LinuxHDD` is configured to expose `/mnt/storage` (not some other location). From Windows, confirm the share can be read and that you can create, read, and delete a small test file on it. Remove the test file before the backup.

Check that `D:` has enough free space for the data plus headroom. Ensure `D:\MediaBackup` is either new or contains no unrelated data. The commands below merge into an existing destination and do not remove destination-only files.

Record which containers/services use `/mnt/storage` and their expected user/group IDs. Inspect the Compose configuration and existing file ownership/permissions before deciding what ownership to apply after formatting. Do not assume every container runs as `kkgmig29`.

Before making the backup, stop or pause every service that can write to `/mnt/storage` so the source does not change during the copy. For the media stack, run this on the server and keep it stopped through formatting and restore:

```bash
cd ~/media-server
docker compose down
```

Stop any other writers as well. If the Samba service is part of the Compose stack, arrange another way to serve the share or use the WSL/SSH option; do not restart a writer just to keep the backup path available. Confirm the chosen backup method still has access to the source after writers are stopped.

## Phase 1: Back Up All Data to Windows

Back up the entire contents of `/mnt/storage` to `D:\MediaBackup` before formatting.

### Option A: Windows PowerShell or Command Prompt

Run on the Windows PC:

```cmd
robocopy "\\192.168.50.32\LinuxHDD" "D:\MediaBackup" /E /COPY:DAT /DCOPY:DAT /MT:16 /R:1 /W:1 /V /TEE /LOG:"D:\MediaBackup-robocopy.log"
```

`/E` copies subdirectories, including empty ones. `/COPY:DAT` and `/DCOPY:DAT` preserve file data, attributes, timestamps, and directory timestamps where supported; Linux ownership and permissions are not represented by this Windows backup. `/MT:16` uses multiple copy threads. `/R:1 /W:1` limits retries. `/LOG` records the results.

After it finishes, inspect the summary. Robocopy exit codes **0–7** indicate no copy failure (though codes 1–7 may report copied files or differences); **8 or higher** means at least one failure and must be resolved before proceeding. Check the log for failed files and rerun the copy as needed.

### Option B: Windows File Explorer

1. Press `Win + R`, enter `\\192.168.50.32\LinuxHDD`, and press Enter.
2. If prompted, use the Linux/Samba account configured for this share.
3. Copy the contents into `D:\MediaBackup`.
4. For a large backup, prefer Option A because its log and exit code make failures easier to identify.

### Option C: WSL with rsync

Use this only if SSH access is enabled and the WSL environment has `rsync` installed. Create the destination directory first:

```bash
mkdir -p /mnt/d/MediaBackup
rsync -avh --no-owner --no-group --no-perms --progress --partial kkgmig29@192.168.50.32:/mnt/storage/ /mnt/d/MediaBackup/
```

Confirm `rsync` exits with status 0 and review its output for errors. The `--no-owner --no-group --no-perms` flags avoid trying to preserve Linux ownership and permissions on the typical Windows-mounted `D:` filesystem. This backup does not preserve Linux ownership, ACLs, or extended attributes.

### Verify the backup

Before touching the server disk:

- Confirm the Robocopy log has no failed files, or (for WSL) that `rsync` completed with exit status 0.
- Compare source and destination folder/file counts and total logical size. The Windows “Size on disk” can differ because of allocation units; use the logical “Size” as a rough comparison, not a sole pass criterion.
- Open representative files from different folders and verify expected top-level folders, including `MediaServer/media/movies` and `MediaServer/media/tv`, are populated.
- For stronger assurance, generate and compare checksums for important data or use a checksum-capable backup process. Do not rely only on visual inspection or approximate size.

Do not format unless the backup is complete, readable, and has enough free space for a full restore.

## Phase 2: Confirm Services Are Stopped and Unmount the Disk

SSH into the server (`ssh kkgmig29@192.168.50.32`):

```bash
cd ~/media-server
docker compose down
docker ps
findmnt /mnt/storage
sudo fuser -vm /mnt/storage
```

The Docker stop here is a final check; all services that write to the disk should already have been stopped before the backup and must remain stopped. Check that no remaining container or service is using the mount. Stop any other processes that use it. Then unmount:

```bash
sudo umount /mnt/storage
```

If unmount reports “target is busy,” use `sudo fuser -vm /mnt/storage` to identify users and stop them cleanly. `lsof +D /mnt/storage` can help, but may take a long time on a large tree. Do not use a lazy or forced unmount as a workaround.

Confirm it is unmounted before formatting:

```bash
findmnt /mnt/storage
```

No mount entry should be returned. Also verify the target device one final time:

```bash
lsblk -f
```

## Phase 3: Format the Drive to ext4

> [!CAUTION]
> Formatting permanently erases `/dev/sda1`. Proceed only after the Windows backup has been independently verified and the unmount and device checks above are correct.

Create the filesystem with 1% reserved blocks:

```bash
sudo mkfs.ext4 -m 1 -L Storage /dev/sda1
```

`-m 1` reserves 1% for privileged use rather than ext4’s typical 5% default. On a roughly 700 GB filesystem, this makes about 28 GB more available to non-root users than a 5% reservation; it does not increase total filesystem capacity.

Read and record the new UUID and confirm the filesystem type:

```bash
sudo blkid /dev/sda1
lsblk -f
```

Confirm `/dev/sda1` reports `TYPE="ext4"`. Copy its UUID for the `fstab` entry.

## Phase 4: Update `/etc/fstab` and Mount

Back up the current file, then edit it:

```bash
sudo cp -a /etc/fstab /etc/fstab.bak
sudo nano /etc/fstab
```

Replace the existing entry for `/mnt/storage` (do not leave duplicate entries) with:

```text
UUID=YOUR_NEW_UUID_HERE /mnt/storage ext4 defaults,noatime 0 2
```

Replace the placeholder with the UUID from `blkid`. Save the file, then check the entry and mount:

```bash
sudo findmnt --verify --verbose
sudo mount /mnt/storage
findmnt -no SOURCE,FSTYPE,UUID,TARGET /mnt/storage
df -hT /mnt/storage
```

Verify the source/UUID is the newly formatted `/dev/sda1`, the filesystem type is `ext4`, and the target is `/mnt/storage` before restoring. Capacity will be somewhat below the marketed disk size because of unit conversion and filesystem metadata; do not use a specific `df` number as the only check.

## Phase 5: Set Access and Restore Data

The new filesystem root is initially owned by `root`. Set access based on the users and groups identified during preflight. For example, if `kkgmig29` and the relevant containers all use that account/group, set the root directory ownership and a suitable group-writable mode:

```bash
sudo chown kkgmig29:kkgmig29 /mnt/storage
sudo chmod 2775 /mnt/storage
```

The setgid bit on the directory makes newly created items inherit its group. This does not recursively change restored files. If containers run under different numeric UIDs/GIDs, configure ownership, ACLs, or group access to match their actual IDs. Avoid blanket `chmod -R 775`: it marks every file executable and can create unintended access. Apply any required ACLs or targeted permission changes after restore.

Restore from the verified backup using the same method used to back up. With Windows Robocopy:

```cmd
robocopy "D:\MediaBackup" "\\192.168.50.32\LinuxHDD" /E /COPY:DAT /DCOPY:DAT /MT:16 /R:1 /W:1 /V /TEE /LOG:"D:\MediaRestore-robocopy.log"
```

Review the log and summary. Resolve any failed files (exit code 8 or higher) and compare the restored folder/file counts and logical size with the backup. Keep the backup unchanged.

If using WSL/SSH instead, first confirm on the server that `findmnt -no SOURCE,FSTYPE,TARGET /mnt/storage` shows the new ext4 filesystem mounted at `/mnt/storage`. Then run in WSL:

```bash
rsync -avh --no-owner --no-group --no-perms --progress --partial /mnt/d/MediaBackup/ kkgmig29@192.168.50.32:/mnt/storage/
```

Confirm `rsync` exits with status 0 and review its output for errors before starting services. This assumes SSH access and that the remote account can write into `/mnt/storage` with the permissions configured above.

## Phase 6: Start Services and Verify

On the server, verify the mount and restored paths before starting containers:

```bash
findmnt -no SOURCE,FSTYPE,UUID,TARGET /mnt/storage
du -sh /mnt/storage
ls -la /mnt/storage
```

Then start the stack:

```bash
cd ~/media-server
docker compose up -d
docker compose ps
```

Check logs using the actual container names shown by Compose (they may not be exactly `plex`, `radarr`, and `sonarr`):

```bash
docker compose logs --tail 30
```

Open Plex Web at `http://192.168.50.32:32400/web`, scan the Movies and TV libraries, and confirm representative media plays. If automatic library updates are enabled, verify by adding a test file through the normal workflow and confirming Plex detects it. ext4 supports inotify, but successful Plex notifications also depend on Plex settings, container mounts, and access to filesystem events.

Keep `D:\MediaBackup` intact until the restored data and applications have been verified.

## Rollback and Recovery

- **Before formatting:** The original data is still on the NTFS disk. If needed, restore the original `/etc/fstab` from `/etc/fstab.bak`, mount the NTFS filesystem, verify `/mnt/storage`, then start the services.
- **After formatting:** The original disk data is gone. The Windows backup is the recovery source. Mount the new ext4 filesystem, ensure the Samba share still exposes `/mnt/storage`, and restore the backup. Do not delete the Windows backup until recovery and service checks pass.
- **If the new mount fails:** Do not copy data into `/mnt/storage` until `findmnt` confirms the ext4 filesystem is mounted there; otherwise files may be written to the server’s root filesystem beneath the mount point.
