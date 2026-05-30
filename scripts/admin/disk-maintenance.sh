#!/bin/bash
# =============================================================================
# Disk maintenance for Wikibase servers
#
# Cleans up common sources of disk bloat on DEV / TEST / PROD:
#   1. Old sync temp files left in /tmp from interrupted sync runs
#   2. Oversized container log files (truncates to 0 -- safe while running)
#   3. Docker build cache
#   4. Reports current disk usage summary
#
# Run interactively on any server:
#   ssh root@<server-ip> 'bash -s' < scripts/admin/disk-maintenance.sh
#
# Or from the cloned repo on the server:
#   bash /opt/wikibase/scripts/admin/disk-maintenance.sh
#
# Flags:
#   --dry-run     Show what would be removed without removing anything
#   --logs-only   Only truncate container logs; skip other steps
# =============================================================================

set -euo pipefail

DRY_RUN=false
LOGS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --logs-only) LOGS_ONLY=true ;;
    esac
done

echo "=== Wikibase Disk Maintenance ==="
[[ "$DRY_RUN" == true ]] && echo "  ** DRY RUN - no changes will be made **"
echo ""

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------
remove_if_exists() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local size
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
        if [[ "$DRY_RUN" == true ]]; then
            echo "  [dry-run] would remove: $path ($size)"
        else
            rm -f "$path"
            echo "  Removed: $path ($size)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — Remove stale sync temp files from /tmp
# These are left behind when a sync run is interrupted before cleanup.
# ---------------------------------------------------------------------------
if [[ "$LOGS_ONLY" != true ]]; then
    echo "--- Step 1: Stale sync temp files in /tmp ---"
    PATTERNS=(
        "/tmp/test_to_prod_*.sql"
        "/tmp/dev_to_prod_*.sql"
        "/tmp/dev_to_test_*.sql"
        "/tmp/local_to_test_*.sql"
        "/tmp/local_to_dev_*.sql"
        "/tmp/images-sync.tar.gz"
        "/tmp/dev-dump-sync.sql"
        "/tmp/restore.sql"
    )
    FOUND=0
    for pattern in "${PATTERNS[@]}"; do
        for f in $pattern; do
            [[ -f "$f" ]] || continue
            remove_if_exists "$f"
            FOUND=$((FOUND + 1))
        done
    done
    [[ "$FOUND" -eq 0 ]] && echo "  Nothing to remove."
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 2 — Truncate large container log files
# Truncating (not deleting) is safe while a container is running.
# Docker continues writing to the same inode.
# ---------------------------------------------------------------------------
echo "--- Step 2: Container log files ---"
LOG_THRESHOLD_BYTES=$((20 * 1024 * 1024))  # 20 MB threshold
LOG_DIR="/var/lib/docker/containers"
TRUNCATED=0

if [[ -d "$LOG_DIR" ]]; then
    while IFS= read -r -d '' logfile; do
        size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
        if (( size > LOG_THRESHOLD_BYTES )); then
            container_id=$(basename "$(dirname "$logfile")")
            container_name=$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | tr -d '/' || echo "$container_id")
            size_mb=$(( size / 1024 / 1024 ))
            if [[ "$DRY_RUN" == true ]]; then
                echo "  [dry-run] would truncate: $container_name log (${size_mb} MB)"
            else
                truncate -s 0 "$logfile"
                echo "  Truncated: $container_name log (was ${size_mb} MB)"
            fi
            TRUNCATED=$((TRUNCATED + 1))
        fi
    done < <(find "$LOG_DIR" -name '*-json.log' -print0 2>/dev/null)
fi

[[ "$TRUNCATED" -eq 0 ]] && echo "  No logs exceed 20 MB threshold."
echo ""

# ---------------------------------------------------------------------------
# Step 3 — Docker build cache
# ---------------------------------------------------------------------------
if [[ "$LOGS_ONLY" != true ]]; then
    echo "--- Step 3: Docker build cache ---"
    CACHE_SIZE=$(docker system df --format '{{.Size}}' 2>/dev/null | tail -1 || echo "unknown")
    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] would prune build cache"
        docker builder prune --dry-run 2>/dev/null || true
    else
        docker builder prune -f
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Step 4 — Disk usage summary
# ---------------------------------------------------------------------------
echo "--- Disk usage summary ---"
df -h / /tmp 2>/dev/null
echo ""
echo "Docker storage:"
docker system df
echo ""
echo "Top 10 container log sizes:"
find /var/lib/docker/containers -name '*-json.log' -exec du -sh {} \; 2>/dev/null \
    | sort -rh | head -10
echo ""
echo "=== Maintenance complete ==="
