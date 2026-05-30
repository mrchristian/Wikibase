#!/bin/bash
# =============================================================================
# Configure Docker log rotation on a Wikibase server
#
# Writes /etc/docker/daemon.json with log rotation settings so that
# container log files never grow unbounded and fill the root filesystem.
#
# Defaults: 50 MB max per log file, 3 rotated files per container
#           (150 MB max per container).  Override with env vars:
#   LOG_MAX_SIZE=100m LOG_MAX_FILES=5 bash configure-docker-log-rotation.sh
#
# Run on each server (DEV / TEST / PROD) once after initial deploy:
#   ssh root@<server-ip> 'bash -s' < scripts/admin/configure-docker-log-rotation.sh
#
# Or run from the cloned repo on the server:
#   bash /opt/wikibase/scripts/admin/configure-docker-log-rotation.sh
#
# Safe to re-run — idempotent. Reloads Docker daemon without stopping
# any running containers.
# =============================================================================

set -euo pipefail

LOG_MAX_SIZE="${LOG_MAX_SIZE:-50m}"
LOG_MAX_FILES="${LOG_MAX_FILES:-3}"
DAEMON_JSON="/etc/docker/daemon.json"

echo "=== Configure Docker log rotation ==="
echo "  max-size : $LOG_MAX_SIZE"
echo "  max-file : $LOG_MAX_FILES"
echo "  config   : $DAEMON_JSON"
echo ""

# ---------------------------------------------------------------------------
# Write daemon.json
# Merge with any existing config if present; otherwise create fresh.
# ---------------------------------------------------------------------------
if [[ -f "$DAEMON_JSON" ]]; then
    echo "Existing $DAEMON_JSON found — merging log-rotation settings..."
    # Use Python to merge so other settings (if any) are preserved.
    python3 - <<PYEOF
import json, sys

with open("$DAEMON_JSON") as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError:
        # Corrupt/empty file — start fresh
        cfg = {}

cfg["log-driver"] = "json-file"
cfg.setdefault("log-opts", {})
cfg["log-opts"]["max-size"] = "$LOG_MAX_SIZE"
cfg["log-opts"]["max-file"] = "$LOG_MAX_FILES"

with open("$DAEMON_JSON", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("  Written.")
PYEOF
else
    echo "Creating $DAEMON_JSON..."
    python3 - <<PYEOF
import json

cfg = {
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "$LOG_MAX_SIZE",
        "max-file": "$LOG_MAX_FILES"
    }
}
with open("$DAEMON_JSON", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("  Written.")
PYEOF
fi

echo ""
echo "Validating JSON..."
python3 -m json.tool "$DAEMON_JSON"

# ---------------------------------------------------------------------------
# Reload Docker daemon (applies to new containers; existing containers keep
# their current log driver until recreated).
# ---------------------------------------------------------------------------
echo ""
echo "Reloading Docker daemon (no container restarts)..."
if systemctl is-active --quiet docker; then
    systemctl reload docker
    echo "  Docker daemon reloaded."
else
    echo "  Docker daemon not running — settings will apply on next start."
fi

echo ""
echo "=== Done. Log rotation active for new containers. ==="
echo "  Note: existing containers use their existing log files."
echo "  Run 'docker compose up -d' to recreate containers with the new limit."
