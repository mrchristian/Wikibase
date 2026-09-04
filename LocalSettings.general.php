<?php
# General site settings (localhost overrides)

$wgSitename = "ClimateKG";
$wgMetaNamespace = "ClimateKG";

$wgLogos = [
	'1x' => "$wgResourceBasePath/images/ckglogo1.png",
	'icon' => "$wgResourceBasePath/images/ckglogo1.svg",
];

# Permissions hardening: anonymous visitors are read-only.
# Logged-in users retain standard editing rights.
$wgGroupPermissions['*']['edit'] = false;
$wgGroupPermissions['*']['createpage'] = false;
$wgGroupPermissions['*']['createtalk'] = false;
$wgGroupPermissions['*']['createaccount'] = false;

$wgGroupPermissions['user']['edit'] = true;
$wgGroupPermissions['user']['createpage'] = true;
$wgGroupPermissions['user']['createtalk'] = true;

# Increase multi-language string length limit so full definitions fit in descriptions.
# Default is 250; raising to 2500 accommodates the longest IPCC glossary entry (~2103 chars).
$wgWBRepoSettings['string-limits']['multilang']['length'] = 2500;

# Increase monolingualtext property value limit (default 400) for IPCC definition statements.
$wgWBRepoSettings['string-limits']['VT:monolingualtext']['length'] = 2500;

# Increase string property value limit (default 400) to accommodate DOI abstracts (~1100 chars).
$wgWBRepoSettings['string-limits']['VT:string']['length'] = 2500;
