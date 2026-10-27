<?php
# =============================================================================
# Custom namespaces
# Mounted into the wikibase container as a LocalSettings.d drop-in.
#
# Namespace IDs 3000/3001 are well above the reserved core range (0-199)
# and the Wikibase extension range (120-147), so there is no conflict.
# Even ID = content namespace; odd ID = its talk namespace.
# =============================================================================

define( 'NS_IPCC',      3000 );
define( 'NS_IPCC_TALK', 3001 );

$wgExtraNamespaces[ NS_IPCC      ] = 'IPCC';
$wgExtraNamespaces[ NS_IPCC_TALK ] = 'IPCC_talk';

# Allow subpages in both the content and talk namespaces.
$wgNamespacesWithSubpages[ NS_IPCC      ] = true;
$wgNamespacesWithSubpages[ NS_IPCC_TALK ] = true;

# Include IPCC pages and Wikibase Item (120) / Property (122) entities in default searches,
# in addition to the main namespace. Users can still narrow this on Special:Search.
$wgNamespacesToBeSearchedDefault[ NS_MAIN ] = true;
$wgNamespacesToBeSearchedDefault[ NS_IPCC ] = true;
$wgNamespacesToBeSearchedDefault[ 120 ] = true;
$wgNamespacesToBeSearchedDefault[ 122 ] = true;