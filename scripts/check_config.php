<?php
chdir("/var/www/html");
require "/config/LocalSettings.php";
echo "siteLinkGroups: ";
var_export($wgWBRepoSettings["siteLinkGroups"] ?? "NOT SET");
echo "\n";
echo "LocalSettings.d files:\n";
print_r(glob("LocalSettings.d/*.php"));
echo "localClientDatabases: ";
var_export($wgWBRepoSettings["localClientDatabases"] ?? "NOT SET");
echo "\n";
