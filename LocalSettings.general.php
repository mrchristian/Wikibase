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

# Default Vector Appearance menu to collapsed on all hosts.
# This primarily affects anonymous users and users without an explicit saved preference.
$wgHooks['SetupAfterCache'][] = static function () {
	global $wgDefaultUserOptions;
	$wgDefaultUserOptions['vector-appearance-pinned'] = 0;
};

# Hide Vector Appearance controls for anonymous users on all hosts.
$wgHooks['BeforePageDisplay'][] = static function ( OutputPage $out, Skin $skin ) {
	if ( $out->getUser()->isRegistered() ) {
		return true;
	}

	$out->addInlineStyle(
		'#vector-appearance-dropdown,' .
		'.vector-appearance-landmark,' .
		'#vector-appearance-pinned-container{display:none !important;}'
	);

	return true;
};

# Logged-out visitors should not see the Vector Add languages menu.
$wgVectorLanguageInHeader = [
	'logged_in' => true,
	'logged_out' => false,
];

# Increase multi-language string length limit so full definitions fit in descriptions.
# Default is 250; raising to 2500 accommodates the longest IPCC glossary entry (~2103 chars).
$wgWBRepoSettings['string-limits']['multilang']['length'] = 2500;

# Increase monolingualtext property value limit (default 400) for IPCC definition statements.
$wgWBRepoSettings['string-limits']['VT:monolingualtext']['length'] = 2500;

# Increase string property value limit (default 400) to accommodate DOI abstracts (~1100 chars).
$wgWBRepoSettings['string-limits']['VT:string']['length'] = 2500;
