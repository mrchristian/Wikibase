# Plan: Provision 4 New TIB Debian Machines (Replace DEV/TEST/PROD + New Import Sandbox)

**Status as of 2026-09-30:** Phases 1-2 (repo config + deploy scripts) and part of Phase 5 (verify-env-sync.ps1 entries) are implemented. **All 4 new machines (new-IMPORT, new-DEV, new-TEST, new-PROD) are fully provisioned and verified end-to-end** (Phase 3 complete). **Phase 4 is now fully complete**: step 13 (old-DEV → new-DEV) and step 14 (new-DEV → new-TEST → new-PROD) have both been run and verified with exact data parity across all three environments (6,289 pages / 2,164 images). Rest of Phase 5-6 (control-plane script updates, cutover) are **not yet executed** — they require explicit go-ahead per step.

## Background

New infrastructure runs on entirely new `tibwiki.io` domains (not a DNS repoint of the existing `semanticclimate.org` domains), so old and new environments can coexist with zero conflict during a **staged validate-then-switch** rollout. Old servers stay running (decommission deferred, not decided yet). The key architectural twist versus the existing `deploy.sh`: TLS is terminated by an external TIB reverse proxy that catch-all forwards every path to each box's own port 80 — so each box still needs a local Nginx for path-splitting (wiki / query-ui / sparql), but **not** Certbot/SSL (that's the external proxy's job).

## Machines

| Role | Host | External URL |
|---|---|---|
| new-DEV | `climatekg01.develop.service.tib.eu` | `https://dev-climatekg.tibwiki.io/` |
| new-TEST | `climatekg11.test.service.tib.eu` | `https://test-climatekg.tibwiki.io/` |
| new-PROD | `climatekg21.service.tib.eu` | `https://climatekg.tibwiki.io/` |
| new-IMPORT | `climatekgdi21.service.tib.eu` | `https://import-climatekg.tibwiki.io/` |

SSH: user `worthingtons`, sudo, key already installed on all 4 boxes. Fresh Debian, Docker **not** yet installed (full bootstrap needed).

## Decisions

- New domains (`tibwiki.io`), **not** a DNS repoint of the old domains (`semanticclimate.org`) — allows the old and new environments to run fully in parallel with zero conflict.
- Old DEV/TEST/PROD (`178.104.156.88` / `46.224.66.24` / `178.105.222.174`) are kept running indefinitely; decommissioning is a separate, deferred decision.
- The Import box gets its own full independent Wikibase stack (sandbox DB), not just tooling — content is promoted to DEV later via a follow-up mini-plan (out of scope here).
- Certbot/SSL is fully skipped on the new boxes — TLS termination is the external TIB reverse proxy's job.
- Existing wrapper/sync scripts for dev/test/prod are **not** mutated until cutover is explicitly approved, to avoid disturbing the old, still-live boxes during the validation window.
- The Windows control-plane workstation is on VPN, so the `*.service.tib.eu` internal hostnames are directly reachable — no blocker for `verify-env-sync.ps1` / `scripts/sync/*.ps1`.

---

## Phase 1 — Repo config changes ✅ DONE

1. ~~Update domain values in `.env.dev.template`, `.env.test.template`, `.env.production`~~ → done (new tibwiki.io domains/hosts). Safe because `.env` itself is gitignored and only ever copied from the template on first deploy — old servers already have their own `.env` and are unaffected.
2. **Correction made during implementation:** `sites.*.xml` and `wdqs-custom-config.*.json` are *not* like `.env` — they are live bind-mounted by hardcoded filename inside `docker-compose.{dev,test,prod}.yml`, which IS tracked by git and re-pulled by the old, still-live servers on every routine update. Overwriting them in place would have broken the old servers' branding/sitelinks on their next `git pull` + rebuild.
   - **Fix:** parameterized the two bind mounts in `docker-compose.{dev,test,prod}.yml` as `${SITES_FILE:-sites.<env>.xml}` and `${WDQS_CONFIG_FILE:-wdqs-custom-config.<env>.json}` — defaults exactly match today's filenames, so old servers are completely unaffected even after a future `git pull`.
   - Created new domain-specific files for the new machines: `sites.dev-new.xml`, `sites.test-new.xml`, `sites.prod-new.xml`, `wdqs-custom-config.dev-new.json`, `wdqs-custom-config.test-new.json`, `wdqs-custom-config.prod-new.json` (all pointing at the new tibwiki.io domains).
   - `.env.dev.template` / `.env.test.template` / `.env.production` now also set `SITES_FILE=sites.<env>-new.xml` and `WDQS_CONFIG_FILE=wdqs-custom-config.<env>-new.json` so a first deploy on a new box automatically picks up the new files.
3. Created a brand-new 4th environment set for **import**: `docker-compose.import.yml`, `sites.import.xml`, `wdqs-custom-config.import.json`, `.env.import.template` — domain `import-climatekg.tibwiki.io`.
4. No changes needed to the service definitions in `docker-compose.*.yml` themselves — domain is already parameterized via `${WIKIBASE_DOMAIN}`, and `LocalSettings*.php` doesn't hardcode any domain (confirmed via grep).

## Phase 2 — Deploy script adaptation ✅ DONE

5. Modified [scripts/deploy/deploy.sh](../scripts/deploy/deploy.sh): added an `EXTERNAL_TLS_PROXY` flag that, when `true`:
   - Skips Certbot install/cert issuance entirely (installs Nginx only).
   - Skips opening port 443 in `ufw` (only 22/80 needed).
   - Skips the "run certbot manually" instructions at the end, replaced with a message confirming TLS is handled upstream and to verify through the external `https://<domain>.tibwiki.io/` URL.
   - Default (`EXTERNAL_TLS_PROXY` unset/`false`) behavior is 100% unchanged — existing `deploy-dev.sh`/`deploy-test.sh`/`deploy-prod.sh` (targeting the old boxes) are unaffected.
6. Created `scripts/deploy/deploy-import.sh` — new wrapper, `EXTERNAL_TLS_PROXY=true`, points at `docker-compose.import.yml` / `.env.import.template`.
7. Created **temporary** wrapper scripts for the new dev/test/prod boxes: `scripts/deploy/deploy-dev-new.sh`, `deploy-test-new.sh`, `deploy-prod-new.sh` — same `COMPOSE_FILE`/`ENV_TEMPLATE` as today (since those already parameterize the new domain/files per Phase 1), `EXTERNAL_TLS_PROXY=true`, pointed at the new hostnames. The existing `deploy-dev.sh`/`deploy-test.sh`/`deploy-prod.sh` are **left untouched** — they still target the old, live boxes. These `-new` wrappers get merged/renamed into the canonical ones only at cutover (Phase 6).

## Phase 3 — Provision each box ✅ DONE (all 4 boxes: new-IMPORT, new-DEV, new-TEST, new-PROD)

Recommended order: **IMPORT or new-DEV first** (lowest risk pilot), then TEST, then PROD last.

8. ✅ SSH in as `worthingtons` (key already installed).
   - **Gotcha found on new-IMPORT (`climatekgdi21`):** the box is a *minimal* Debian 13 (trixie) netinstall — `sudo`, `curl`, `git`, and `ufw` were **all missing**, even though `worthingtons` was already correctly in the `sudo` group. `sudo` itself being absent is a catch-22 (can't `sudo apt install sudo`) — required one manual `su -` (root password typed directly into the terminal by the user, never by the agent) to install `sudo` and add a passwordless `/etc/sudoers.d/worthingtons` entry. After that, `apt-get install -y curl git ufw` (via sudo) closed the remaining gaps. **Assume this is true for new-DEV/TEST/PROD too** — budget for the same bootstrap step.
9. ✅ Bootstrap: Docker installed cleanly via `deploy.sh`'s `get.docker.com` step once `curl` was present.
10. ✅ Clone repo to `/opt/wikibase`, run `sudo bash scripts/deploy/deploy-import.sh` directly on the box (not piped from Windows — piping a `.sh` file through a PowerShell pipe risks CRLF/encoding corruption of the bash script, per existing repo memory; cloning the repo and running the script in place avoids this entirely).
    - **Important:** all Phase 1/2 file changes must be **committed and pushed** to `origin/master` before a fresh box's `git clone`/`git pull` can see them — this was initially missed (the new-machines files existed only in the local Windows working tree) and had to be corrected with a commit + push mid-session.
    - `.env` is created `root:root 0600` when the script runs via `sudo` — use `sudo docker compose ...` for any follow-up management commands (matches the old servers' root-SSH convention, just via `sudo` instead of direct root login).
11. ✅ Verified locally on new-IMPORT: `docker compose ps` — all 5 containers (`wikibase`, `wikibase-mariadb`, `wikibase-wdqs`, `wikibase-wdqs-frontend`, `wikibase-wdqs-updater`) healthy; `curl localhost:8080/8081/9999` all returned 200; Nginx Host-header path-split (`curl -H "Host: import-climatekg.tibwiki.io" http://127.0.0.1/...`) returned 200 for both `/wiki/Main_Page` and `/query/`.
12. ✅ Verified end-to-end through the external TIB proxy from the Windows workstation: `https://import-climatekg.tibwiki.io/wiki/Main_Page` → 200, `https://import-climatekg.tibwiki.io/query/` → 200. TIB reverse proxy is correctly wired to the box.

**new-DEV (`climatekg01.develop.service.tib.eu`) — repeated steps 8-12, all ✅ DONE:**
- Same missing `sudo`/`curl`/`git`/`ufw` gotcha confirmed again — bootstrapped via `su -` (root password typed directly by the user) the same way.
- **New gotcha:** after `apt-get install ufw`, a plain (non-sudo) `command -v ufw` still reported missing — `ufw`'s binary lives in `/usr/sbin`, which is on `sudo`'s `secure_path` but **not** on the interactive non-root user's default `$PATH` (`/usr/local/bin:/usr/bin:/bin:/usr/games`). This is a non-issue in practice since `deploy.sh` always invokes `ufw` via `sudo`, but worth knowing so a `command -v ufw` health-check script doesn't false-negative diagnose it as missing.
- **Terminal-handoff lesson (re-confirmed, see also user memory `vscode-terminal-handoff.md`):** when multiple terminal tabs are open, it's easy for the user to type a root password/passphrase into a *different* tab than the one the agent is watching. When this happened, the agent's queued follow-up command was silently consumed as a (failed) SSH passphrase attempt, burning an auth attempt and eventually causing the server to close the connection after too many failures. **Mitigation used:** fell back to a manual relay — asked the user to run the exact bootstrap command directly in their own root terminal and paste back the output, rather than attempting further terminal handoff. No secrets were exposed or logged in either case (the queued text wasn't a real secret, just a misdirected command), but the auth attempts were burned and the session had to be restarted.
- Deployed via `sudo bash scripts/deploy/deploy-dev-new.sh`, all 5 containers healthy, local ports 8080/8081/9999 all 200, Nginx Host-header split 200 for both `/wiki/Main_Page` and `/query/`, external `https://dev-climatekg.tibwiki.io/` wiki + `/query/` both 200 through the TIB reverse proxy.
- Admin credentials retrieved via `sudo grep -E '^MW_ADMIN' /opt/wikibase/.env` (username `admin`, password auto-generated, stored in `.env` on the box).
- **⚠️ Superseded after Phase 4 migration (2026-09-30):** the old-DEV→new-DEV DB migration overwrote new-DEV's `user` table, so new-DEV's `.env` `MW_ADMIN_PASS` is now stale — it only seeded the admin account on first deploy into what was then an empty DB. The admin login that actually works now is **old DEV's** `.env` `MW_ADMIN_PASS` value (username `admin`), since that's whose `user` table row was migrated in. Re-check `MW_ADMIN_PASS` on **old DEV** (`root@178.104.156.88`), not new-DEV, until/unless the admin password is explicitly reset on new-DEV post-migration.

**new-TEST (`climatekg11.test.service.tib.eu`) — repeated steps 8-12, all ✅ DONE:**
- Same missing `sudo`/`curl`/`git`/`ufw` gotcha confirmed a third time — bootstrapped via `su -` the same way, this time without any terminal-handoff mishap (verified terminal state with `get_terminal_output` before sending each command, per the lesson learned from new-DEV).
- Deployed via `sudo bash scripts/deploy/deploy-test-new.sh`, all 5 containers healthy, local ports 8080/8081/9999 all 200, Nginx Host-header split 200 for both `/wiki/Main_Page` and `/query/`, external `https://test-climatekg.tibwiki.io/` wiki + `/query/` both 200 through the TIB reverse proxy.
- Admin credentials retrieved via `sudo grep -E '^MW_ADMIN' /opt/wikibase/.env` (username `admin`, password auto-generated, stored in `.env` on the box).

**new-PROD (`climatekg21.service.tib.eu`) — repeated steps 8-12, all ✅ DONE:**
- Same missing `sudo`/`curl`/`git`/`ufw` gotcha confirmed a fourth time — bootstrapped via `su -` the same way, no terminal-handoff mishap (verified terminal state with `get_terminal_output` before sending the bootstrap command).
- Deployed via `sudo bash scripts/deploy/deploy-prod-new.sh`, all 5 containers healthy, local ports 8080/8081/9999 all 200, Nginx Host-header split 200 for both `/wiki/Main_Page` and `/query/`, external `https://climatekg.tibwiki.io/` wiki + `/query/` both 200 through the TIB reverse proxy.
- Admin credentials retrieved via `sudo grep -E '^MW_ADMIN' /opt/wikibase/.env` (username `admin`, password auto-generated, stored in `.env` on the box).

**All 4 new TIB machines are now fully provisioned and verified end-to-end as of 2026-09-30.**

## Phase 4 — Data population ✅ DONE (steps 13 and 14 both complete)

13. ✅ **DONE (2026-09-30):** new-DEV migrated from old DEV's DB + uploaded images. New one-off script created: [scripts/sync/migrate-olddev-to-newdev.ps1](../scripts/sync/migrate-olddev-to-newdev.ps1) — modeled on `sync-dev-to-test.ps1`'s pattern (`mysqldump --result-file=` inside the container, `docker cp` out, never redirect with `>`/`|` from PowerShell — see repo memory), but resolves both source (old DEV, root, `id_wikibase_sync` passphrase-free key) and target (new-DEV, `worthingtons` + sudo, `id_rsa` passphrase-protected key) DB credentials **live via SSH grep** rather than a local plaintext `.env` copy. Supports a `-DbOnly` switch to skip the images sync.
    - Old DEV DB dump: 846.5 MB. Images archive (thumbnails excluded): 755.2 MB.
    - Ran `update.php --quick` + `rebuildrecentchanges` on new-DEV post-import, restarted `wikibase-sitelinks-init` then `wikibase`.
    - **Verified parity:** both old DEV and new-DEV report identical counts — **6,289 pages / 2,164 images**.
    - **Verified externally:** `https://dev-climatekg.tibwiki.io/wiki/Main_Page` → 200, `https://dev-climatekg.tibwiki.io/query/` → 200.
    - **Minor non-fatal issue noted:** `TRUNCATE TABLE IF EXISTS objectcache` failed with a MariaDB syntax error (`TRUNCATE` doesn't support `IF EXISTS` in this MariaDB version) — harmless, `update.php` still ran cleanly afterward. Script should be fixed to drop `IF EXISTS` from the `TRUNCATE` statements before reuse.
14. ✅ **DONE (2026-09-30):** new-DEV's data promoted forward to new-TEST, then new-TEST's data promoted forward to new-PROD. Two new one-off scripts created, modeled on `sync-test-to-prod.ps1`'s pattern (DROP DATABASE + CREATE DATABASE + stdin-redirect import, plus an admin-password-reset step) combined with `migrate-olddev-to-newdev.ps1`'s live-credential-resolution and images-tar pattern:
    - [scripts/sync/migrate-newdev-to-newtest.ps1](../scripts/sync/migrate-newdev-to-newtest.ps1) — new-DEV → new-TEST.
    - [scripts/sync/migrate-newtest-to-newprod.ps1](../scripts/sync/migrate-newtest-to-newprod.ps1) — new-TEST → new-PROD (requires typing `PROMOTE` to confirm, production target).
    - Both include a step 6 that resets the *target's own* `.env` `MW_ADMIN_PASS` back onto the admin account post-migration (via `maintenance/run.php changePassword`), fixing the stale-admin-password gotcha found on new-DEV (see step 13 note above) — confirmed working on both new-TEST and new-PROD.
    - **Bug found and fixed:** both scripts' images-extraction command originally chained `&& chown -R www-data:www-data ... && rm ...` after the `tar -xzf` step. `chown` fails with `Read-only file system` on the 2 preserved default logo files (`ckglogo1.png`/`ckglogo1.svg`, baked into the Docker image layer), which broke the `&&` chain and made the SSH command return non-zero — the PowerShell script's `Die()` check then incorrectly treated this as a fatal images-extraction failure and aborted before the final verification step, even though the `tar` extraction itself had already succeeded. **Fix:** changed the chain to `; chown ... 2>/dev/null; rm -f ...` (softened to non-fatal) in both scripts before running the new-PROD promotion.
    - **Verified parity:** new-TEST and new-PROD both report **6,289 pages / 2,164 images** in the database (matching new-DEV/old-DEV), and ~2,190-2,193 real image files on disk (small variance from DB row count is expected/normal, not a discrepancy).
    - **Verified externally:** `https://test-climatekg.tibwiki.io/` and `https://climatekg.tibwiki.io/` both return 200 on `/wiki/Main_Page` and `/query/`.
    - **Diagnostic false-alarm noted:** an initial `find ... -type f ... | wc -l` file-count check on new-TEST returned `3` (suggesting near-empty), directly contradicted by a `find -maxdepth 3` listing run moments later showing hundreds of real files. Re-running the count with simplified `-not -path "*thumb*"` (rather than the original `-not -path "*/thumb/*" -not -name .htaccess -not -name README`) returned the correct **2,190** — the original command's quoting/predicate combination was faulty, not the underlying data. Lesson: don't trust a single `find`-based count if it looks anomalously low; corroborate with a DB-level `SELECT COUNT(*) FROM image` check, which is authoritative.
15. new-IMPORT: stands up with a fresh/empty DB (sandbox) — no migration needed initially.

## Phase 5 — Control-plane script updates (Windows workstation) 🟡 PARTIALLY DONE

16. ✅ Added **new** entries (not overwritten) to `scripts/verify-env-sync.ps1`'s `$environments` array: `DEV-NEW`, `TEST-NEW`, `PROD-NEW`, `IMPORT` — labeled distinctly so old and new can be monitored side-by-side during validation. Also added a `UseSudo` field since the new boxes authenticate as `worthingtons` + sudo rather than `root`, and wired it into the remote DB-timestamp check.
17. ✅ Confirmed: the Windows workstation is on VPN, so the `*.service.tib.eu` hostnames are directly reachable — no blocker.
18. 🔲 Still to do: one-off migration script(s) for Phase 4 steps 13-14, rather than mutating the existing recurring `scripts/sync/*.ps1` (those keep targeting the old hosts until cutover).

## Phase 6 — Cutover (after validation signed off) 🔲 NOT STARTED

19. Update `deploy-dev.sh`/`deploy-test.sh`/`deploy-prod.sh` to point at the new tibwiki.io domains/hosts (or simply rename the `-new` wrappers to replace them), treating the new boxes as canonical going forward.
20. Update `scripts/sync/*.ps1` and `scripts/wdqs-reindex-prod.ps1` host variables to the new hostnames for ongoing routine use.
21. Update `docs/deployment-protocol.md` Server Registry table and `devops-plan.md` with the new machines; mark the old boxes "legacy / kept as fallback".

---

## Relevant files

- `scripts/deploy/deploy.sh` — `EXTERNAL_TLS_PROXY` conditional (done)
- `scripts/deploy/deploy-dev.sh`, `deploy-test.sh`, `deploy-prod.sh` — untouched, domain flip deferred to cutover
- `scripts/deploy/deploy-dev-new.sh`, `deploy-test-new.sh`, `deploy-prod-new.sh`, `deploy-import.sh` — new temporary wrappers (done)
- `.env.dev.template`, `.env.test.template`, `.env.production`, `.env.import.template` (done)
- `sites.dev.xml`, `sites.test.xml`, `sites.prod.xml` — untouched (still old domain, default fallback)
- `sites.dev-new.xml`, `sites.test-new.xml`, `sites.prod-new.xml`, `sites.import.xml` — new (done)
- `wdqs-custom-config.dev.json`, `.test.json`, `.prod.json` — untouched (still old domain, default fallback)
- `wdqs-custom-config.dev-new.json`, `.test-new.json`, `.prod-new.json`, `.import.json` — new (done)
- `docker-compose.dev.yml`, `.test.yml`, `.prod.yml` — parameterized bind mounts (done)
- `docker-compose.import.yml` — new (done)
- `scripts/verify-env-sync.ps1` — 4 new entries added (done)
- `scripts/sync/*.ps1`, `scripts/wdqs-reindex-prod.ps1` — host flip deferred to cutover
- `docs/deployment-protocol.md`, `devops-plan.md` — registry + migration notes, deferred to cutover

## Verification checklist

1. `docker compose ps` all containers healthy on each new box.
2. Local curl checks (`localhost:8080`/`8081`/`9999`) + Nginx path-split checks (Host header) on each box.
3. External curl checks through `https://*.tibwiki.io/` for wiki, query UI, SPARQL proxy.
4. `verify-env-sync.ps1` run against the new entries — `ChapterCount`/`Q128Triples` parity vs. DEV baseline once data is migrated.
5. Manual login test through the external HTTPS proxy (confirms no CSRF/cookie-secure issues from TLS being terminated upstream instead of locally — same pattern already proven on the current prod setup).

## Further considerations (deferred, out of scope for this plan)

- The Import→DEV promotion workflow isn't fully designed yet — planned as a follow-up mini-plan once the import box is live, modeled on the existing LOCAL experimental-import pattern.
- Decommissioning the old DEV/TEST/PROD Hetzner servers is deferred — no timeline set.
