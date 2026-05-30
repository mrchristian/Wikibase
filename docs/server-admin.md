# Server Administration — ClimateKG Wikibase

> **Documentation hierarchy**
> | Doc | Role |
> |---|---|
> | [`docs/multi-env-workflow.md`](multi-env-workflow.md) | **Master reference** — how to operate all environments, run scripts, promote content |
> | `devops-plan.md` | Planning log — itemised task list, design decisions, build rationale |
> | `docs/deployment-protocol.md` | Historical deployment log; server registry |
> | `docs/hetzner-deploy-guide.md` | One-time server provisioning on Hetzner |
> | **`docs/server-admin.md`** (this file) | Server resource management, disk, logs, maintenance |
> | Admin scripts | [`scripts/admin/configure-docker-log-rotation.sh`](../scripts/admin/configure-docker-log-rotation.sh) · [`scripts/admin/disk-maintenance.sh`](../scripts/admin/disk-maintenance.sh) |

This document covers ongoing server administration for the DEV, TEST, and PROD servers: disk management, Docker log rotation, and routine maintenance.

---

## 1. Disk Space Overview

Each server is a Hetzner CX22 VM with a **75 GB root disk**. The disk fills quickly because:

| Source | Typical size | Notes |
|--------|-------------|-------|
| Docker images | 60–70 GB | Wikibase + MariaDB + WDQS images; largely unavoidable |
| Docker volumes | 2–3 GB | MariaDB data, WDQS triple store |
| Container logs | 0–700 MB | Unbounded by default; can grow to hundreds of MB per container |
| `/tmp` sync files | 0–2 GB | SQL dumps and image tarballs left over from interrupted sync runs |
| Docker build cache | 50–900 MB | Intermediate build layers; fully reclaimable |

### Checking disk usage

```sh
# Disk usage overview
df -h /

# Docker storage breakdown
docker system df

# Container log sizes
find /var/lib/docker/containers -name '*-json.log' \
  -exec du -sh {} \; | sort -rh | head -10

# What is in /tmp
du -sh /tmp/* 2>/dev/null | sort -rh | head -10
```

---

## 2. Docker Log Rotation (one-time setup)

By default Docker writes container logs to unbounded JSON files under
`/var/lib/docker/containers/`. On a busy server these can grow to hundreds
of megabytes and silently fill the root filesystem.

### Configure log rotation

Run once on each server after initial deploy:

```sh
ssh root@<server-ip> 'bash -s' < scripts/admin/configure-docker-log-rotation.sh
```

Or from the cloned repo on the server:

```sh
bash /opt/wikibase/scripts/admin/configure-docker-log-rotation.sh
```

This writes `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
```

**Effect**: each container keeps at most 3 × 50 MB = 150 MB of logs. Older entries rotate out automatically.

**Important**: The setting applies to **new or recreated containers**. Existing containers retain their current (unbounded) log file until the container is recreated with `docker compose up -d`.

To override the defaults:

```sh
LOG_MAX_SIZE=100m LOG_MAX_FILES=5 bash scripts/admin/configure-docker-log-rotation.sh
```

### Current status (PROD)

Log rotation was configured on PROD (178.105.222.174) on **2026-05-29** after container logs had grown to ~660 MB total and contributed to a full-disk incident. All servers should have this applied.

| Server | IP | Log rotation configured |
|--------|----|------------------------|
| DEV    | 178.104.156.88  | Yes (2026-05-29) |
| TEST   | 46.224.66.24    | Yes (2026-05-29) |
| PROD   | 178.105.222.174 | Yes (2026-05-29) |

---

## 3. Disk Maintenance Script

The `disk-maintenance.sh` script handles the most common sources of disk bloat in a single pass:

1. Removes stale sync temp files from `/tmp` (SQL dumps, image tarballs)
2. Truncates container log files larger than 20 MB
3. Prunes Docker build cache
4. Prints a disk usage summary

### Usage

```sh
# Run on a specific server
ssh root@<server-ip> 'bash -s' < scripts/admin/disk-maintenance.sh

# Dry run — show what would be removed without changing anything
ssh root@<server-ip> 'bash -s' < scripts/admin/disk-maintenance.sh -- --dry-run

# Truncate logs only (skip tmp cleanup and build cache)
ssh root@<server-ip> 'bash -s' < scripts/admin/disk-maintenance.sh -- --logs-only
```

### When to run

- Any time `df -h /` shows usage above 90%
- After a sync run is interrupted before completing (leaves temp files in `/tmp`)
- Periodically as a precaution before running a large sync

---

## 4. Manual Disk Recovery

If the automated script is not available or the disk is too full to run it, use these steps directly on the server.

### Step 1 — Remove stale /tmp sync files

```sh
# List what is in /tmp
du -sh /tmp/* 2>/dev/null | sort -rh

# Remove old SQL dumps and image tarballs
rm -f /tmp/*.sql /tmp/images-sync.tar.gz /tmp/restore.sql
```

### Step 2 — Truncate large container logs

Truncating (not deleting) is safe while the container is running. Docker continues writing to the same inode; the on-disk size becomes 0.

```sh
# Find large log files
find /var/lib/docker/containers -name '*-json.log' \
  -exec du -sh {} \; | sort -rh | head -10

# Truncate a specific log (replace <container-id> with the directory name)
truncate -s 0 /var/lib/docker/containers/<container-id>/*-json.log

# Or truncate all at once (be aware this clears all container history)
find /var/lib/docker/containers -name '*-json.log' -exec truncate -s 0 {} \;
```

### Step 3 — Prune Docker build cache

```sh
docker builder prune -f
```

### Step 4 — Check if enough space is now free

```sh
df -h /
```

The sync scripts write ~416 MB SQL dumps to `/tmp` (tmpfs, separate from `/`). The `docker cp` step (old sync scripts) wrote an additional ~416 MB into the container overlay on `/`. The updated sync scripts use `docker exec -i ... mysql < /tmp/file` which avoids copying into the overlay entirely.

---

## 5. Hetzner Disk Resize

If disk cleanup is not sufficient, resize the root volume in Hetzner Cloud:

1. Log in to [console.hetzner.cloud](https://console.hetzner.cloud)
2. Select the project → **Servers** → select the server (DEV / TEST / PROD)
3. **Rescale** → choose a larger server type (CX22 → CX32 adds 40 GB)
   - Or keep the same CPU/RAM and only resize the disk via **Volumes** if using a separate volume
4. The server must be **powered off** during a resize that changes root disk size
5. After powering back on, run:
   ```sh
   # Verify new size is recognised
   df -h /
   # If not, grow the partition (Ubuntu 24.04 usually auto-grows on reboot)
   resize2fs /dev/sda1
   ```

> **Note**: Downsizing is not possible; you can only resize upward.

---

## 6. Swap & Memory Configuration

All three servers have 3.7 GB RAM. With Docker containers for Wikibase, MariaDB, WDQS, and wdqs-updater all running simultaneously, available memory can drop below 500 MB. Without a swap file the kernel OOM-killer will terminate container processes, causing freezes or unexpected restarts.

### Configuration applied (all servers)

| Setting | Value | Rationale |
|---------|-------|----------|
| Swap file | 2 GB `/swapfile` | Emergency RAM overflow buffer |
| `vm.swappiness` | 10 | Only use swap when RAM is ~90% full — avoids constant disk I/O |
| `vm.vfs_cache_pressure` | 50 | Hold page cache longer — reduces MariaDB/Wikibase disk I/O |

### Current status

| Server | IP | Swap | Memory tuning configured |
|--------|----|------|-------------------------|
| DEV    | 178.104.156.88  | 2 GB | Yes (2026-05-29) |
| TEST   | 46.224.66.24    | 2 GB | Yes (2026-05-29) |
| PROD   | 178.105.222.174 | 2 GB | Yes (2026-05-29) |

### Verify on a server

```sh
# Check swap is active
free -h
swapon --show

# Check sysctl values
sysctl vm.swappiness vm.vfs_cache_pressure

# Check it survives reboots
grep swapfile /etc/fstab
cat /etc/sysctl.d/90-wikibase-memory.conf
```

### Re-apply on a new server

If deploying a fresh server, run these steps once after the initial deploy:

```sh
ssh root@<server-ip>

# Create and enable swap file
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# Persist memory tuning
printf 'vm.swappiness = 10\nvm.vfs_cache_pressure = 50\n' > /etc/sysctl.d/90-wikibase-memory.conf
sysctl -p /etc/sysctl.d/90-wikibase-memory.conf
```

---

## 7. Incident Record

### 2026-05-29 — PROD disk full during TEST→PROD sync

**Symptom**: `scp` to PROD failed at 0% with `write remote: Failure`. Error message in `sync-test-to-prod.ps1`:

```
C:\WINDOWS\System32\OpenSSH\scp.exe: write remote "/tmp/...sql": Failure
[ERROR] SCP to PROD failed. Check that PROD is not out of disk space
```

**Cause**: Both `/` (75 GB root, 100% full) and `/tmp` (1.9 GB tmpfs, 100% full) were full.

Root causes:
- `/tmp`: 3 old SQL dumps (~1.16 GB) + `images-sync.tar.gz` (746 MB) left over from previous sync runs that had not cleaned up after themselves
- `/` root: two container logs had grown unbounded — `wikibase-mariadb` log (467 MB), `wikibase` log (195 MB)

**Resolution**:
1. Cleared `/tmp` — freed the tmpfs entirely (1.9 GB)
2. Truncated container logs — freed ~662 MB on `/`
3. Completed the sync manually using `docker exec -i ... mysql < /tmp/file` (stdin pipe) rather than `docker cp`, avoiding writing into the container overlay on the full `/`
4. Configured Docker log rotation on PROD (`/etc/docker/daemon.json`)
5. Updated `sync-test-to-prod.ps1` and `sync-dev-to-prod.ps1` to use stdin pipe import instead of `docker cp` + `mysql source`

**Follow-up actions** (all completed):
- ~~Apply log rotation to DEV and TEST~~ — done 2026-05-29 (see §2)
- ~~Consider resizing PROD disk~~ — Hetzner disk resize completed; PROD now has 62 GB free (see §5)
- ~~Add swap to all servers~~ — done 2026-05-29 (see §6)
