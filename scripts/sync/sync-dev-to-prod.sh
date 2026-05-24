#!/bin/bash
# Bash wrapper to run PowerShell sync script in WSL with proper SSH agent setup

set -euo pipefail

echo "==============================================="
echo "DEV → PROD Database Sync"
echo "==============================================="
echo ""
echo "WARNING: This will overwrite PRODUCTION with DEV data"
echo ""

# Accept confirmation as argument or prompt
if [ "${1:-}" = "PROMOTE" ]; then
    confirm="PROMOTE"
else
    read -p "Type PROMOTE to confirm: " confirm
fi

if [ "$confirm" != "PROMOTE" ]; then
    echo "Aborted - no changes made"
    exit 0
fi

# Setup SSH agent
eval "$(ssh-agent -s)" > /dev/null 2>&1 || true
ssh-add ~/.ssh/id_rsa < <(echo "doublerainboom") 2>/dev/null || true

# Configuration
DEV_HOST="178.104.156.88"
PROD_HOST="178.105.222.174"
DEV_DB_USER="wikibase"
PROD_DB_USER="wikibase"
DB_NAME="my_wiki"
DEV_CONTAINER="wikibase-mariadb"
PROD_CONTAINER="wikibase-mariadb"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DUMP_FILENAME="dev_to_prod_$TIMESTAMP.sql"
BACKUP_DIR="/mnt/c/Wikibase/backups"

# Read passwords from .env - convert to unix path
ENV_FILE="/mnt/c/Wikibase/.env"
DEV_DB_PASS=$(grep "^DEV_DB_PASS" "$ENV_FILE" 2>/dev/null | tr -d '\r' | cut -d= -f2 || echo "")
PROD_DB_PASS=$(grep "^PROD_DB_PASS" "$ENV_FILE" 2>/dev/null | tr -d '\r' | cut -d= -f2 || echo "")

if [ -z "$DEV_DB_PASS" ] || [ -z "$PROD_DB_PASS" ]; then
    echo "[ERROR] Database passwords not found in .env"
    echo "Add these lines to C:\\Wikibase\\.env:"
    echo "  DEV_DB_PASS=<password>"
    echo "  PROD_DB_PASS=<password>"
    exit 1
fi

echo ""
echo "=== 1/8  Dumping DEV database ==="
ssh root@$DEV_HOST "cd /opt/wikibase && docker exec $DEV_CONTAINER mysqldump -u $DEV_DB_USER -p'$DEV_DB_PASS' --result-file=/tmp/$DUMP_FILENAME $DB_NAME" || true
ssh root@$DEV_HOST "docker cp $DEV_CONTAINER:/tmp/$DUMP_FILENAME /tmp/$DUMP_FILENAME"
echo "[OK] Dump created on DEV host"

echo ""
echo "=== 2/8  Downloading dump to LOCAL ==="
scp "root@$DEV_HOST:/tmp/$DUMP_FILENAME" "$BACKUP_DIR/$DUMP_FILENAME"
filesize=$(stat -f%z "$BACKUP_DIR/$DUMP_FILENAME" 2>/dev/null || stat -c%s "$BACKUP_DIR/$DUMP_FILENAME")
if [ "$filesize" -lt 1000000 ]; then
    echo "[ERROR] Dump is too small ($filesize bytes) - mysqldump likely failed"
    exit 1
fi
echo "[OK] Dump: $((filesize / 1000000)) MB - $BACKUP_DIR/$DUMP_FILENAME"

echo ""
echo "=== 3/8  Cleaning up DEV temp files ==="
ssh root@$DEV_HOST "docker exec $DEV_CONTAINER rm -f /tmp/$DUMP_FILENAME; rm -f /tmp/$DUMP_FILENAME" || true
echo "[OK] Cleaned up DEV temp files"

echo ""
echo "=== 4/8  Uploading dump to PROD ==="
scp "$BACKUP_DIR/$DUMP_FILENAME" "root@$PROD_HOST:/tmp/$DUMP_FILENAME"
echo "[OK] Dump at /tmp/$DUMP_FILENAME on PROD"

echo ""
echo "=== 5/8  Importing dump into PROD database ==="
ssh root@$PROD_HOST "docker cp /tmp/$DUMP_FILENAME $PROD_CONTAINER:/tmp/restore.sql && docker exec $PROD_CONTAINER bash -c 'mysql -u $PROD_DB_USER -p\"$PROD_DB_PASS\" $DB_NAME < /tmp/restore.sql && rm /tmp/restore.sql'"
ssh root@$PROD_HOST "rm -f /tmp/$DUMP_FILENAME"
echo "[OK] Database imported on PROD"

echo ""
echo "=== 6/8  Truncating caches on PROD ==="
ssh root@$PROD_HOST "docker exec $PROD_CONTAINER bash -c 'mysql -u $PROD_DB_USER -p\"$PROD_DB_PASS\" $DB_NAME -e \"TRUNCATE TABLE objectcache; TRUNCATE TABLE l10n_cache;\"'"
echo "[OK] Caches truncated"

echo ""
echo "=== 7/8  Running MediaWiki update on PROD ==="
ssh root@$PROD_HOST "docker exec wikibase php /var/www/html/maintenance/run.php update.php"
echo "[OK] MediaWiki update completed"

echo ""
echo "=== 8/8  Restarting PROD containers ==="
ssh root@$PROD_HOST "cd /opt/wikibase && docker compose -f docker-compose.yml -f docker-compose.prod.yml restart wikibase"
echo "[OK] Containers restarted"

echo ""
echo "=============================================="
echo "✓ DEV → PROD sync COMPLETE!"
echo "=============================================="
echo "PROD is now running with DEV data"
echo "Access at: http://prod-climatekg.semanticclimate.org/"
echo ""
