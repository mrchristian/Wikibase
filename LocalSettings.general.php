<?php
# General site settings (localhost overrides)

$wgSitename = "ClimateKG";
$wgMetaNamespace = "ClimateKG";

$wgLogos = [
	'1x' => "$wgResourceBasePath/images/ckglogo1.png",
	'icon' => "$wgResourceBasePath/images/ckglogo1.svg",
];

# Desktop uses Vector 2022; the mobile view (MobileFrontend) uses Minerva via $wgMFDefaultSkinClass below.
$wgDefaultSkin = 'vector-2022';

# OpenSearch / CirrusSearch backend wiring for the local Wikibase stack.
# These extensions are present in the WBS image and need to be enabled explicitly.
if ( file_exists( "$IP/extensions/Elastica/extension.json" ) ) {
	wfLoadExtension( 'Elastica' );
}
if ( file_exists( "$IP/extensions/CirrusSearch/extension.json" ) ) {
	wfLoadExtension( 'CirrusSearch' );
}
if ( file_exists( "$IP/extensions/WikibaseCirrusSearch/extension.json" ) ) {
	wfLoadExtension( 'WikibaseCirrusSearch' );
	$wgWBCSUseCirrus = true;
}

$wgSearchType = 'CirrusSearch';
$wgCirrusSearchServers = [
	[
		'host' => 'opensearch',
		'port' => 9200,
		'transport' => 'http',
		'path' => '',
	],
];
$wgCirrusSearchIndexBaseName = 'mywiki';

# Enable MobileFrontend explicitly when the extension is available in the image.
# This keeps the container bootable even before the mobile extension is added,
# but it configures the site to use the installed Minerva mobile skin once present.
if ( file_exists( "$IP/extensions/MobileFrontend/extension.json" ) ) {
	wfLoadExtension( 'MobileFrontend' );
	$wgMFDefaultSkinClass = 'SkinMinerva';
	$wgMFAutodetectMobileView = true;
	$wgMFShowMobileViewToTablets = true;
	$wgMFVaryOnUA = true;
}

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

# Footer links (standard SkinAddFooterLinks hook): Data protection, Imprint and Accessibility statement.
# About, Disclaimers and Privacy policy use MediaWiki's built-in message slots (defaults).
$wgHooks['SkinAddFooterLinks'][] = static function ( Skin $skin, string $key, array &$footerItems ) {
	if ( $key !== 'places' ) {
		return;
	}

	$links = [
		'data-protection' => [ 'Project:Data protection', 'Data protection' ],
		'imprint' => [ 'Imprint', 'Imprint' ],
		'accessibility' => [ 'Accessibility statement', 'Accessibility statement' ],
	];

	foreach ( $links as $id => [ $pageName, $label ] ) {
		$title = \MediaWiki\Title\Title::newFromText( $pageName );
		if ( !$title ) {
			continue;
		}
		$footerItems[$id] = \MediaWiki\Html\Html::element(
			'a',
			[ 'href' => $title->getLocalURL() ],
			$label
		);
	}
};

# Minerva hides the About footer link (duplicate of the hamburger menu entry); show it first in the footer.
# The SkinAddFooterLinks hook cannot reorder existing items, so order is set with CSS flex.
$wgHooks['BeforePageDisplay'][] = static function ( OutputPage $out, Skin $skin ) {
	if ( in_array( $skin->getSkinName(), [ 'minerva', 'vector-2022' ], true ) ) {
		$out->addInlineStyle(
			'#footer-places{display:flex;flex-wrap:wrap;}' .
			'#footer-places-about{display:inline-block !important;order:-1;}'
		);
	}
};

# Minerva (mobile) hamburger menu: hide the About and Disclaimers entries (they remain in the footer).
$wgHooks['BeforePageDisplay'][] = static function ( OutputPage $out, Skin $skin ) {
	if ( $skin->getSkinName() === 'minerva' ) {
		$out->addInlineStyle(
			'.menu__item--about,.menu__item--disclaimers{display:none !important;}'
		);
	}
};

# Increase multi-language string length limit so full definitions fit in descriptions.
# Default is 250; raising to 2500 accommodates the longest IPCC glossary entry (~2103 chars).
$wgWBRepoSettings['string-limits']['multilang']['length'] = 2500;

# Increase monolingualtext property value limit (default 400) for IPCC definition statements.
$wgWBRepoSettings['string-limits']['VT:monolingualtext']['length'] = 2500;

# Increase string property value limit (default 400) to accommodate DOI abstracts (~1100 chars).
$wgWBRepoSettings['string-limits']['VT:string']['length'] = 2500;
