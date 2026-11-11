<?php
# =============================================================================
# Restrict login and account creation to administrators (PROD only).
# Mounted into the wikibase container as a LocalSettings.d drop-in by
# docker-compose.prod.yml. Anonymous readers are unaffected.
#
# - Nobody can self-register; only administrators can create accounts.
# - Only users in $ckgLoginAllowedGroups can log in (web login and main-account
#   API login). Everyone else gets the same generic refusal.
# - Maintenance scripts (CLI) do not go through this check.
#
# To allow another group, add it to $ckgLoginAllowedGroups below.
# =============================================================================

$ckgLoginAllowedGroups = [ 'sysop', 'bureaucrat', 'interface-admin' ];

# Account creation: nobody self-registers; sysops keep the default 'createaccount'.
$wgGroupPermissions['*']['createaccount'] = false;
$wgGroupPermissions['user']['createaccount'] = false;
$wgGroupPermissions['sysop']['createaccount'] = true;

if ( class_exists( \MediaWiki\Auth\AbstractPreAuthenticationProvider::class )
	&& !class_exists( 'ClimateKGAdminOnlyLogin', false )
) {
	class ClimateKGAdminOnlyLogin extends \MediaWiki\Auth\AbstractPreAuthenticationProvider {
		/** @var string[] */
		private $allowedGroups;

		public function __construct( array $params = [] ) {
			$this->allowedGroups = $params['allowedGroups'] ?? [ 'sysop' ];
		}

		public function testForAuthentication( array $reqs ) {
			$name = \MediaWiki\Auth\AuthenticationRequest::getUsernameFromRequests( $reqs );
			if ( $name === null ) {
				return \StatusValue::newGood();
			}

			$services = \MediaWiki\MediaWikiServices::getInstance();
			$user = $services->getUserFactory()->newFromName( $name );
			if ( $user && $user->isRegistered() ) {
				$groups = $services->getUserGroupManager()->getUserGroups( $user );
				if ( array_intersect( $this->allowedGroups, $groups ) ) {
					return \StatusValue::newGood();
				}
			}

			return \StatusValue::newFatal(
				wfMessage( 'rawmessage', 'Login is restricted to administrators.' )
			);
		}
	}

	$wgAuthManagerAutoConfig['preauth']['ClimateKGAdminOnlyLogin'] = [
		'class' => 'ClimateKGAdminOnlyLogin',
		'args' => [ [ 'allowedGroups' => $ckgLoginAllowedGroups ] ],
		'sort' => 0,
	];
}
