# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows semantic-style release notes where practical.

## [Unreleased]

### Added
- Added `LICENCE` with GNU General Public License v3.0 text.
- Added `CHANGELOG.md` to track project changes.
- Added `scripts/deploy/switch-git-remote.sh` to point a server's `/opt/wikibase` clone at TIB GitLab (read-only deploy key or token); old remote kept as `github`.
- Added `--env newdev` to `scripts/update-chapter-wiki-urls.py` (targets `dev-climatekg.tibwiki.io`; `--env dev` still targets the old DEV).
- Added `scripts/remove-stale-sitelink.py` to remove a retired sitelink site id (e.g. `mywiki`) from item JSON via `wbeditentity`.

### Changed
- `scripts/deploy/deploy.sh` `REPO_URL` now defaults to TIB GitLab (override with `REPO_URL=...`).
- `scripts/deploy/init-sitelinks.sh` is idempotent for duplicate `mywiki` sitelinks (`UPDATE IGNORE` + delete leftovers) and upserts the interwiki row.

### Deployed (new-DEV, 2026-10-29)
- new-DEV (`dev-climatekg.tibwiki.io`) upgraded to MW 1.46.2 with OpenSearch/CirrusSearch; WDQS reloaded (~141.7k triples); P5 URLs on `tibwiki.io`.
- Lesson: removing the `mywiki` row from `sites` leaves `mywiki` in item JSON; `Special:EntityData` then prints PHP warnings into the Turtle output and the wdqs-updater gives up on that item (`RDF parsing error`). Fix: re-register the site temporarily (`importSites`), run `remove-stale-sitelink.py`, rerun `wikibase-sitelinks-init`. Check before TEST/PROD: `SELECT` pages in ns 120 whose text contains `"mywiki"`.
- Lesson: an auto-created plain `mywiki_content` index blocks `UpdateSearchIndexConfig --startOver`; delete it first and build the Cirrus index before any API edits.
- Lesson: keep `wdqs-updater` stopped until the WDQS reload finishes; the updater only retries a failed entity on a new edit.
- Docs (`docs/multi-env-workflow.md`, `docs/hetzner-deploy-guide.md`) now describe TIB GitLab as the source of truth, GitHub as a backup mirror.

### Security
- Moved OpenSearch ports 9200/9600 from `docker-compose.yml` to `docker-compose.override.yml` (local only) so DEV/TEST/PROD do not publish an unauthenticated OpenSearch on all interfaces.

## [2026-10-28]

### Fixed
- Local `wikibase-wdqs-updater` crash loop ("RDF store reports the last update time is before the minimum safe poll time"). Wiped the local `wdqs_data` volume and reloaded WDQS from a fresh `dumpRdf.php` export (3,986 entities, 141,715 triples, concept URI `http://localhost:8080`). The updater now starts from the dump timestamp and polls normally.

### Changed
- `docs/mw-update-checklist.md`: SPARQL check now points to `http://localhost:9999/bigdata/namespace/wdq/sparql` (the root URL returns 404 by design); added a local graph query to the Query UI check.

### Verified (LOCAL, mw1.46.2)
- All containers healthy with 0 restarts; MariaDB 10.11.19; OpenSearch cluster green (3 indices green).
- Wiki pages, custom namespaces (IPCC 3000, Item 120, Property 122, EntitySchema 640) and full-text/entity search respond correctly.
- All SPARQL queries from `docs/sparql-api-tests-and-graph-queries.md` return data on localhost when the base URI is changed to `http://localhost:8080`.

### Known issues
- DEV/TEST/PROD (mw1.45) have not yet been updated or tested with the OpenSearch/mw1.46.2 changes; DEV update planned next.
- `docs/sparql-api-tests-and-graph-queries.md` queries use `prod-climatekg.semanticclimate.org` URIs; each environment needs its own base URI.
- No scripted WDQS wipe/reload exists yet; the local reload was run manually.

## [2026-10-27]

### Added
- Added `opensearch` service (`wikibase/opensearch:os1.3.20`, ports 9200/9600, `opensearch_data` volume) to `docker-compose.yml`.
- Installed Elastica, CirrusSearch, WikibaseCirrusSearch and MobileFrontend in `Dockerfile.wikibase`.
- Added `scripts/deploy/ensure-localsettings-d.sh` bootstrap entrypoint so project `LocalSettings.d` drop-ins load under the mw1.46 config layout.
- Added `.gitattributes` forcing LF line endings for `*.sh` and `Dockerfile*`.

### Changed
- Upgraded local Wikibase images from `mw1.45.0` to `mw1.46.2` (`Dockerfile.wikibase`, `docker-compose.yml`, `docker-compose.base-image.yml`).
- LocalSettings drop-ins now mounted at `/config/LocalSettings.d/` (loaded via `MW_CONFIG_FILE`/`InstanceSettings.php`).
- `LocalSettings.general.php`: CirrusSearch enabled as search backend (`opensearch:9200`, index base name `mywiki`); extension loading guarded on `extension.json`; default skin set to Minerva with MobileFrontend.
- `LocalSettings.namespaces.php`: IPCC (3000), Item (120) and Property (122) now searched by default alongside Main. Changing this requires rebuilding the Cirrus indices (`UpdateSearchIndexConfig --startOver` then `ForceSearchIndex`).
- `scripts/deploy/init-sitelinks.sh` now uses `MW_CONFIG_FILE` so `$wgServer` is set under mw1.46 (fixes `wikibase-sitelinks-init` failure).
- README refocused to TIB-first DevOps deployment workflow.
- Added TIB infrastructure ASCII schematic at the top of README.
- Main workflow emphasized as DEV -> TEST -> PROD.
- IMPORT documented as a disconnected clean sandbox for import tests.
- Added local experimental loop documentation (CLEAN -> EXPERIMENTAL -> approve/rollback).

### Known issues
- `wikibase-wdqs-updater` crash-looped locally (RDF store last update time is before the minimum safe poll time); resolved 2026-10-28.
- DEV/TEST/PROD (mw1.45) have not yet been updated or tested with the OpenSearch/mw1.46.2 changes.

### Infrastructure
- Primary git remote switched to TIB GitLab deployment repository.
- GitHub remote retained as backup mirror.
