<?php
/**
 * Maintenance script to remove the legacy 'mywiki' sitelink from Q128.
 * Run: php maintenance/run.php /path/to/remove-mywiki-sitelink.php
 * Or:  php /path/to/remove-mywiki-sitelink.php
 */

$IP = '/var/www/html';
require_once "$IP/maintenance/Maintenance.php";

class RemoveMywikiSitelink extends Maintenance {
    public function __construct() {
        parent::__construct();
        $this->addDescription( 'Remove legacy mywiki sitelink from Q128' );
    }

    public function execute() {
        $entityIdParser = \Wikibase\Repo\WikibaseRepo::getEntityIdParser();
        $entityId = $entityIdParser->parse( 'Q128' );

        $entityLookup = \Wikibase\Repo\WikibaseRepo::getEntityLookup();
        $item = $entityLookup->getEntity( $entityId );

        if ( !$item ) {
            $this->error( 'Q128 not found!' );
            return;
        }

        $siteLinks = $item->getSiteLinkList();
        $this->output( 'Current sitelinks: ' );
        foreach ( $siteLinks->toArray() as $sl ) {
            $this->output( $sl->getSiteId() . ':' . $sl->getPageName() . ' ' );
        }
        $this->output( "\n" );

        if ( !$siteLinks->hasLinkWithSiteId( 'mywiki' ) ) {
            $this->output( "No mywiki sitelink found — nothing to do.\n" );
            return;
        }

        // Build a new SiteLinkList without mywiki
        $newSiteLinks = new \Wikibase\DataModel\SiteLinkList();
        foreach ( $siteLinks->toArray() as $sl ) {
            if ( $sl->getSiteId() !== 'mywiki' ) {
                $newSiteLinks->addSiteLink( $sl );
            }
        }
        $item->setSiteLinkList( $newSiteLinks );
        $this->output( "Removed mywiki sitelink.\n" );

        $entityStore = \Wikibase\Repo\WikibaseRepo::getEntityStore();
        $user = User::newSystemUser( 'Maintenance script', [ 'steal' => true ] );

        $entityStore->saveEntity(
            $item,
            'Remove legacy mywiki sitelink to fix WDQS RDF parsing error',
            $user,
            EDIT_UPDATE
        );

        $this->output( "Q128 saved successfully.\n" );

        // Show remaining sitelinks
        $savedItem = $entityLookup->getEntity( $entityId );
        $this->output( 'Remaining sitelinks: ' );
        foreach ( $savedItem->getSiteLinkList()->toArray() as $sl ) {
            $this->output( $sl->getSiteId() . ':' . $sl->getPageName() . ' ' );
        }
        $this->output( "\n" );
    }
}

$maintClass = RemoveMywikiSitelink::class;
require_once RUN_MAINTENANCE_IF_MAIN;
