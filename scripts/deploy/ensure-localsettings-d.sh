#!/usr/bin/env bash
set -eu

# Ensure the WBS-generated configuration exists before we add project overrides.
if [ ! -f /config/LocalSettings.php ] || [ ! -f /config/InstanceSettings.php ]; then
    /var/www/html/extensions/WikibaseSuite/setup/setup.sh
fi

mkdir -p /config/LocalSettings.d

# The upstream WBS config generator writes /config/LocalSettings.php but does not
# automatically include project-local drop-ins. Add the project config bundle once
# so namespace and branding overrides remain active across rebuilds.
if [ -f /config/LocalSettings.php ] && ! grep -Fq "LocalSettings.d/*.php" /config/LocalSettings.php; then
    cat >> /config/LocalSettings.php <<'PHP'

# Project-local overrides installed from the repository.
foreach ( glob( __DIR__ . '/LocalSettings.d/*.php' ) as $projectConfigFile ) {
    require_once $projectConfigFile;
}
PHP
fi

# Start the application with the standard PHP+Apache entrypoint used by the base image.
exec docker-php-entrypoint apache2-foreground "$@"
