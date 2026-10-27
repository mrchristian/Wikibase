# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project follows semantic-style release notes where practical.

## [Unreleased]

### Added
- Added `LICENCE` with GNU General Public License v3.0 text.
- Added `CHANGELOG.md` to track project changes.

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
- `wikibase-wdqs-updater` crash-loops locally (RDF store last update time is before the minimum safe poll time); needs a WDQS journal wipe and reload.
- DEV/TEST/PROD (mw1.45) have not yet been updated or tested with the OpenSearch/mw1.46.2 changes.

### Infrastructure
- Primary git remote switched to TIB GitLab deployment repository.
- GitHub remote retained as backup mirror.
