# new-PROD upgrade to MW 1.46.2 + OpenSearch - status and TODO

Target: `climatekg21.service.tib.eu` / `https://climatekg.tibwiki.io` (behind Basic Auth).
Started 2026-11-10. Same procedure as new-DEV (2026-10-29) and new-TEST (2026-10-30).

## Access (no admin rights on workstation)
- Windows ssh-agent cannot be enabled. Use Git Bash:
  `eval "$(ssh-agent -s)"; ssh-add ~/.ssh/id_rsa`, then run all `ssh` commands from that window.
- Do not use `<` redirection in PowerShell; use Git Bash for piping scripts to the server.

## Done
- [x] Docker had been stopped deliberately on 2026-10-21; restarted with agreement.
- [x] Backups on the server (`/home/worthingtons`): `prod_pre_upgrade_20261110.sql` (849 MB, 6,289 pages / 2,164 images),
      `wikibase_config_pre_upgrade_20261110.tgz`, `nginx-wikibase.pre-upgrade.bak`.
- [x] Server `origin` switched to TIB GitLab (read-only deploy key added); pulled to `147e2d5`.
- [x] Old local server edits stashed: `server-local-edits-2026-11-10` (hardcoded Basic Auth in `deploy-prod-new.sh`, Wikidata examples/brand edits in `wdqs-custom-config.prod-new.json`).
- [x] nginx `/query/proxy/sparql` patched with `limit_except GET HEAD OPTIONS { deny all; }`.
- [x] Images built; stack up WITHOUT `wdqs-updater`; `update.php` run; MediaWiki 1.46.2 confirmed.
- [x] Temporary `mywiki` site registered (group `climatekg-wiki`) so the stale sitelink can be removed.
- [x] `--env newprod` added to `scripts/update-chapter-wiki-urls.py` (and works with `remove-stale-sitelink.py`).
- [x] Admin password reset to the server's `.env` `MW_ADMIN_PASS` via `changePassword` (command exited 0; output not seen - verify by logging in).

## TODO (in order)
1. [x] (done 2026-11-11) Wait >= 5 min after the last failed login (throttle), then in PowerShell (venv):
       `python scripts\remove-stale-sitelink.py --env newprod --site mywiki Q128 --dry-run`, then without `--dry-run`.
       Password = server `/opt/wikibase/.env` `MW_ADMIN_PASS` (type at the prompt, or set `NEWPROD_MW_ADMIN_PASS` in local `.env`).
2. [x] (done 2026-11-11) On the server: `sudo docker compose -f docker-compose.yml -f docker-compose.prod.yml up wikibase-sitelinks-init`
       (fixes the `climatekg-wiki` interwiki row, still `http://localhost/wiki/$1`, and removes `mywiki`), then `restart wikibase`.
3. [x] (done 2026-11-11; content 4,101 + general 2,188 = 6,289) CirrusSearch: delete the auto-created plain `mywiki_content` index, then
       `UpdateSearchIndexConfig --startOver`, `ForceSearchIndex --skipLinks --indexOnSkip`, then `--skipParse`.
4. [x] (done 2026-11-11; 88 chapters on tibwiki.io) P5 URLs: `python scripts\update-chapter-wiki-urls.py --env newprod --dry-run`, then apply.
5. [x] (done 2026-11-11; 141,714 triples, 88 chapters, updater running) WDQS reload (WDQS data is stale, from before 2026-10-21): stop/remove `wdqs`, `wdqs-frontend`, `wdqs-updater`;
       `docker volume rm wdqs_data`; `up -d wdqs`; `dumpRdf.php` with the PROD concept URI; munge + `loadData.sh`;
       then `up -d wdqs-updater wdqs-frontend`. Keep the updater stopped until the load is done.
6. [x] Verify: SPARQL POST to `/query/proxy/sparql` returns 403; 6,289 pages; `ps` all healthy; Cirrus index built;
       automated checks of `docs/mw-update-checklist.md` pass (pages 200, namespaces, extensions, search, sitelinks).
       Still manual (browser): login, branding/mobile, Query UI graph query, editing a QID/PID/page.
7. [x] Commit and push local changes (`scripts/update-chapter-wiki-urls.py`, `temp-mywiki-sites.newprod.xml`, this note);
       add a "Deployed (new-PROD)" entry to `CHANGELOG.md`.

## Follow-ups
- [ ] Remove Basic Auth from PROD (user decision 2026-11-10, deferred to the next morning). Do it only after the TODO list above is
      done or knowingly accepted, since the site is public once auth is off. Steps on the server: back up
      `/etc/nginx/sites-available/wikibase`, `sudo sed -i '/auth_basic/d'` on it, `sudo nginx -t && sudo systemctl reload nginx`,
      then check `https://climatekg.tibwiki.io/wiki/Main_Page` returns 200 without credentials. Optionally delete
      `/etc/nginx/.htpasswd-wikibase`. The repo wrapper `deploy-prod-new.sh` already has Basic Auth off, so it matches.
- [ ] Rotate the Basic Auth password (it is plaintext in the `deploy-*-new.sh` wrappers) and move it to `.env`.
- [ ] Align `scripts/deploy/deploy-prod-new.sh` with the real PROD state (Basic Auth is enabled in nginx on PROD);
      do not re-run `deploy.sh` with the current wrapper or it will drop Basic Auth.
- [ ] Drop the server stash once nothing in it is needed.
- [ ] Revoke the GitLab access token that is embedded in a file name in `~/.ssh`, and delete that file.
