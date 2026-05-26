#!/bin/bash
set -e

echo "=== Wikibase Sitelinks Initialization ==="

# Remove any legacy 'mywiki' entries (renamed to 'climatekg-wiki').
# Uses || true so this is a no-op on environments that never had mywiki.
echo "Removing legacy 'mywiki' site entries (if present)..."
cd /var/www/html
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "DELETE si FROM site_identifiers si INNER JOIN sites s ON si.si_site = s.site_id WHERE s.site_global_key = 'mywiki';" 2>&1 || true
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "DELETE FROM sites WHERE site_global_key = 'mywiki';" 2>&1 || true
echo "[OK] Legacy mywiki site entries removed"

# Migrate existing sitelink data from mywiki to climatekg-wiki
echo "Migrating existing sitelinks from 'mywiki' to 'climatekg-wiki'..."
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "UPDATE wb_items_per_site SET ips_site_id = 'climatekg-wiki' WHERE ips_site_id = 'mywiki';" 2>&1 || true
echo "[OK] Existing sitelinks migrated"

# Import sites into the database
echo "Importing sites from sites.xml..."
cd /var/www/html
if /usr/local/bin/php maintenance/run.php importSites --conf /config/LocalSettings.php /extra-config/sites.xml 2>&1; then
    echo "[OK] Sites imported successfully"
elif /usr/local/bin/php maintenance/importSites.php --conf /config/LocalSettings.php /extra-config/sites.xml 2>&1; then
    echo "[OK] Sites imported successfully (legacy method)"
else
    echo "[ERROR] Failed to import sites"
    exit 1
fi

# Set the site language (required by SiteLinksView to render without errors)
echo "Setting site language for climatekg-wiki..."
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query \
    "UPDATE sites SET site_language = 'en' WHERE site_global_key = 'climatekg-wiki' AND (site_language IS NULL OR site_language = '');" 2>&1
echo "[OK] Site language set to 'en'"

# Fix site_domain and site_protocol (importSites can corrupt these fields).
# Extract correct values from the site_data paths which are imported correctly.
# Note: site_domain must be reachable from inside the container for API validation.
# For LOCAL, use 'localhost' (not 'localhost:8080') since port 8080 is only on host.
echo "Fixing site_domain and site_protocol..."
SITE_FIX_SQL="
UPDATE sites
SET
    site_protocol = CASE
        WHEN site_data LIKE '%https://%' THEN 'https'
        WHEN site_data LIKE '%http://%' THEN 'http'
        ELSE site_protocol
    END,
    site_domain = CASE
        WHEN site_data LIKE '%localhost:8080%' THEN 'localhost'
        WHEN site_data LIKE '%dev-climatekg.semanticclimate.org%' THEN 'dev-climatekg.semanticclimate.org'
        WHEN site_data LIKE '%test-climatekg.semanticclimate.org%' THEN 'test-climatekg.semanticclimate.org'
        WHEN site_data LIKE '%prod-climatekg.semanticclimate.org%' THEN 'prod-climatekg.semanticclimate.org'
        ELSE site_domain
    END
WHERE site_global_key = 'climatekg-wiki';
"
/usr/local/bin/php maintenance/run.php sql --conf /config/LocalSettings.php --query "$SITE_FIX_SQL" 2>&1 || true
echo "[OK] Site domain and protocol configured"

echo ""
echo "=== Sitelinks initialization complete ==="
echo "Now restart the wikibase container to load the new PHP settings:"
echo "  docker compose restart wikibase"
