<?php
error_reporting(E_ALL);
ini_set('display_errors', 1);
echo "STEP1: Starting\n";
$r = chdir("/var/www/html");
echo "STEP2: chdir result=" . ($r ? 'true' : 'false') . "\n";
echo "STEP3: cwd=" . getcwd() . "\n";
echo "STEP4: /config/LocalSettings.php exists=" . (file_exists('/config/LocalSettings.php') ? 'yes' : 'no') . "\n";
echo "STEP5: Including LocalSettings.php\n";
include "/config/LocalSettings.php";
echo "STEP6: Done including\n";
echo "siteLinkGroups: ";
var_export($wgWBRepoSettings["siteLinkGroups"] ?? "NOT SET");
echo "\nFiles in LocalSettings.d:\n";
print_r(glob("LocalSettings.d/*.php"));
