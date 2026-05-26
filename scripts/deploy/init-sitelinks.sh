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
echo "[OK] Legacy mywiki entries removed"

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

echo ""
echo "=== Sitelinks initialization complete ==="
echo "Now restart the wikibase container to load the new PHP settings:"
echo "  docker compose restart wikibase"
