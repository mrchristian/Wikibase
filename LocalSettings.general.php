<?php
# General site settings (localhost overrides)

$wgSitename = "ClimateKG";
$wgMetaNamespace = "ClimateKG";

$wgLogos = [
	'1x' => "$wgResourceBasePath/images/ckglogo1.png",
	'icon' => "$wgResourceBasePath/images/ckglogo1.svg",
];

# Increase multi-language string length limit so full definitions fit in descriptions.
# Default is 250; raising to 2500 accommodates the longest IPCC glossary entry (~2103 chars).
$wgWBRepoSettings['string-limits']['multilang']['length'] = 2500;

# Increase monolingualtext property value limit (default 400) for IPCC definition statements.
$wgWBRepoSettings['string-limits']['VT:monolingualtext']['length'] = 2500;
