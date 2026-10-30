# Storage Migration Plan: NTFS to ext4

This guide contains the complete, step-by-step procedure to migrate your media drive (`/mnt/storage`) from **NTFS** to **ext4** without data loss.

---

## Current Environment Summary

| Component | Value | Notes |
| :--- | :--- | :--- |
| **Media Server IP** | `192.168.50.32` | Linux server running Docker media stack |
| **Media Disk** | `/dev/sda1` | Currently NTFS, mounted at `/mnt/storage` |
| **Used Storage** | **~442 GB** | Total capacity ~699 GB (~258 GB free) |
| **Windows PC** | `192.168.50.161` (`MIG29-PC`) | Backup host with free disk space on `D:` |
| **Backup Path** | `D:\MediaBackup` | Local folder on Windows PC |
| **Network Link** | LAN (1 Gbps) | ~110 MB/s transfer speed (~50–60 min copy) |

---

## Phase 1: Back Up All Data to Windows

You must back up the entire contents of `/mnt/storage` to `D:\MediaBackup` on your Windows PC before formatting.

### Option A: Using Windows PowerShell or CMD (Recommended & Fastest)

> [!IMPORTANT]
> If you run this in **PowerShell**, **Command Prompt (cmd)**, or **Git Bash / Zsh**, you must quote the paths so backslashes and slashes are not misinterpreted by your shell:

Open **PowerShell** or **Command Prompt** (as Administrator) on your Windows PC:

```cmd
robocopy "\\192.168.50.32\LinuxHDD" "D:\MediaBackup" /E /MT:16 /R:1 /W:1
```

* **`/E`**: Copies all subdirectories, including empty ones.
* **`/MT:16`**: Multi-threaded (16 simultaneous streams) to saturate 1 Gbps LAN (~110 MB/s).
* **`/R:1 /W:1`**: Only retry once with a 1-second wait on locked files instead of hanging.

---

### Option B: Using Windows File Explorer (Visual Drag-and-Drop)

1. Press `Win + R`, type:
   ```text
   \\192.168.50.32\LinuxHDD
   ```
   and press **Enter**.
2. If prompted for credentials, use your Linux server username (`kkgmig29`) and Samba password.
3. Select all folders inside (`MediaServer`, `Downloads`, etc.), copy them, and paste them into `D:\MediaBackup`.

---

### Option C: Using WSL on your Windows PC

From your WSL terminal on Windows:

```bash
rsync -avh --progress kkgmig29@192.168.50.32:/mnt/storage/ /mnt/d/MediaBackup/
```

---

### Verification: Confirm Backup is Complete

Before touching the server disk, verify the backup size:
* On Windows, right-click `D:\MediaBackup` → **Properties**.
* Confirm **Size on disk** is approximately **~435–442 GB**.
* Check that both `MediaServer/media/movies` and `MediaServer/media/tv` folders are populated.

---

## Phase 2: Stop Docker Services & Unmount Disk

SSH into your Linux server (`ssh kkgmig29@192.168.50.32`):

```bash
# 1. Navigate to your media-server directory
cd ~/media-server

# 2. Stop all running media containers
docker compose down

# 3. Verify no containers are locking /mnt/storage
docker ps

# 4. Unmount the NTFS partition
sudo umount /mnt/storage
```

> [!NOTE]
> If `sudo umount /mnt/storage` says "target is busy", find what process is using it with:
> `sudo lsof +D /mnt/storage` or `sudo fuser -mv /mnt/storage`
> and terminate that process.

---

## Phase 3: Format the Drive to ext4

> [!CAUTION]
> This command will erase all data on `/dev/sda1`. Ensure Phase 1 backup verification was completed before executing this step!

Run `mkfs.ext4` with the `-m 1` flag (sets reserved superuser blocks to 1% instead of Linux's default 5%, which instantly grants you an extra **~28 GB** of usable free space):

```bash
sudo mkfs.ext4 -m 1 -L Storage /dev/sda1
```

Once formatting completes, get the new disk **UUID**:

```bash
sudo blkid /dev/sda1
```

You will see output similar to:
```text
/dev/sda1: LABEL="Storage" UUID="a1b2c3d4-e5f6-7890-abcd-ef1234567890" BLOCK_SIZE="4096" TYPE="ext4" PARTUUID="..."
```

Copy the string inside `UUID="..."`.

---

## Phase 4: Update `/etc/fstab` & Permissions

### 1. Back up your existing `fstab`:

```bash
sudo cp /etc/fstab /etc/fstab.bak
```

### 2. Edit `/etc/fstab`:

```bash
sudo nano /etc/fstab
```

Find the old line for `/mnt/storage` (which used `ntfs3` or `ntfs`). Replace it with the new `ext4` entry:

```text
UUID=YOUR_NEW_UUID_HERE /mnt/storage ext4 defaults,noatime 0 2
```
*(Replace `YOUR_NEW_UUID_HERE` with the actual UUID from `blkid`)*.

Press `Ctrl + O` then `Enter` to save, and `Ctrl + X` to exit.

### 3. Mount the new ext4 drive:

```bash
sudo mount -a
```

### 4. Verify the mount:

```bash
df -h /mnt/storage
```
* You should see `TYPE: ext4` and approximately **~690 GB** total available.

### 5. Set correct user ownership:

Ensure your user (`kkgmig29`) owns the directory so Docker containers and Samba can write without permission errors:

```bash
sudo chown -R kkgmig29:kkgmig29 /mnt/storage
sudo chmod -R 775 /mnt/storage
```

---

## Phase 5: Restore All Data from Windows

Now copy everything back from `D:\MediaBackup` to the newly formatted ext4 drive on the Linux server.

### Using Windows PowerShell / CMD:

```cmd
robocopy "D:\MediaBackup" "\\192.168.50.32\LinuxHDD" /E /MT:16 /R:1 /W:1
```

Wait for Robocopy to finish (~50–60 minutes).

---

## Phase 6: Start Media Stack & Verification

Back on the Linux server:

```bash
# 1. Start the Docker containers
cd ~/media-server
docker compose up -d

# 2. Check container status
docker compose ps

# 3. Check Plex / Radarr / Sonarr logs for clean startup
docker logs --tail 30 plex
docker logs --tail 30 radarr
docker logs --tail 30 sonarr
```

### 4. Verify in Plex:
1. Open Plex Web (`http://192.168.50.32:32400/web`).
2. Trigger a library scan for Movies and TV Shows.
3. In **Settings → Library**, check **"Update my library automatically"** — on ext4, Linux kernel `inotify` works natively, so new downloads will now be recognized instantly!

---

## Rollback Plan (If Needed)

If anything fails before formatting:
* Your data remains safe on `/mnt/storage`. Simply run `sudo mount -a` and `docker compose up -d`.

If you already formatted `/dev/sda1` and want to abort:
* All your data is safely stored in `D:\MediaBackup` on your Windows PC.
* You can re-copy it at any time back to `/mnt/storage` via `\\192.168.50.32\LinuxHDD`.
