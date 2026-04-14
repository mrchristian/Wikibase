<?php
/**
 * SPARQL extension configuration for ClimateKG Wikibase
 *
 * Enables Lua-based SPARQL query execution via the ProfessionalWiki SPARQL
 * extension. Lua modules can call sparql.runQuery() to query Blazegraph
 * directly and template the results in wikitext.
 *
 * Usage in a Lua module (e.g. Module:SPARQL):
 *   local sparql = require('SPARQL')
 *   local results = sparql.runQuery('SELECT ?item WHERE { ?item a wikibase:Item }')
 *
 * See: https://www.mediawiki.org/wiki/Extension:SPARQL
 */

wfLoadExtension( 'SPARQL' );

// Point to the internal Blazegraph container — avoids nginx round-trips,
// works identically in both local dev and production.
$wgSPARQLEndpoint = 'http://wdqs:9999/bigdata/namespace/wdq/sparql';
