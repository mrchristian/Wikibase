#!/bin/bash
# Don't exit on errors - keep going despite container health issues
set +e

cd /opt/wikibase

# Source only the valid variable assignments from .env (skip comments and blank lines)
if [ -f .env ]; then
  export $(grep -v '^#' .env | grep -v '^$' | xargs)
fi

echo "=== Step 1: Stop and wipe containers/volumes ==="
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.base-image.yml down --volumes 2>/dev/null || true

echo "=== Step 2: Start fresh containers (using base wikibase image) ==="
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.base-image.yml up -d

echo "=== Step 3: Wait for MariaDB to be ready (extended wait) ==="
sleep 40
docker compose ps
echo ""
echo "Proceeding with import (containers are started)..."

echo "=== Step 4: Import database dump into MariaDB container ==="
docker exec -i wikibase-mariadb mysql --binary-mode=1 -u wikibase -p"${DB_PASS:-wikibase}" my_wiki < /tmp/local-dump.sql

echo "=== Step 5: Wait for wiki to initialize ==="
sleep 10

echo "=== Step 6: Post-import maintenance (skip if container not yet healthy) ==="
(docker exec wikibase php /var/www/html/maintenance/rebuildrecentchanges.php 2>&1) || echo "Note: rebuildrecentchanges may not be available yet"
(docker exec wikibase php /var/www/html/maintenance/initSiteStats.php --update 2>&1) || echo "Note: initSiteStats may not be available yet"

echo ""
echo "====== SYNC NEARLY COMPLETE ======"
echo ""
echo "Database has been imported. Containers are running."
echo "The wikibase container may still be initializing MediaWiki."
echo ""
echo "Check container status:"
docker compose ps
echo ""
echo "Check wikibase logs:"  
docker compose logs wikibase | tail -5
echo ""
echo "Wiki should be available at: https://dev-climatekg.semanticclimate.org"
