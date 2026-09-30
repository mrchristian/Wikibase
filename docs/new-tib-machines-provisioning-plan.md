# Plan: Provision 4 New TIB Debian Machines (Replace DEV/TEST/PROD + New Import Sandbox)

**Status as of 2026-09-30:** Phases 1-2 (repo config + deploy scripts) and part of Phase 5 (verify-env-sync.ps1 entries) are implemented. Phases 3-4 (live server provisioning + data migration) and the remainder of Phase 5-6 are **not yet executed** — they require live SSH access to the new boxes and explicit go-ahead per step, since they touch real (if not-yet-serving) infrastructure.

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

## Phase 3 — Provision each box 🔲 NOT STARTED (requires live SSH, needs go-ahead per machine)

Recommended order: **IMPORT or new-DEV first** (lowest risk pilot), then TEST, then PROD last.

8. SSH in as `worthingtons` (key already installed), confirm sudo works, confirm OS/specs match expectations.
9. Bootstrap: `apt update && apt upgrade`, install Docker (`get.docker.com`), git — all handled by `deploy.sh` step 1-2.
10. Clone repo to `/opt/wikibase`, run the appropriate wrapper (`deploy-import.sh` / `deploy-dev-new.sh` / etc.), which sources `deploy.sh` with `EXTERNAL_TLS_PROXY=true`.
11. Verify locally: `docker compose ps` all healthy; `curl localhost:8080`, `:8081`, `:9999` all respond; Nginx port-80 path-split works via `curl -H "Host: <domain>" http://localhost/...`.
12. Verify end-to-end through the external TIB proxy: `curl https://<new-domain>.tibwiki.io/` (wiki), `/query/` (query UI), `/query/proxy/sparql` (SPARQL) — confirms the TIB reverse proxy is correctly wired to the box.

## Phase 4 — Data population 🔲 NOT STARTED (depends on Phase 3 per box)

13. new-DEV: migrate current DEV's DB + uploaded images using the established safe pattern — `mysqldump --result-file=` inside the container, then `docker cp` out (never redirect with `>`/`|` from PowerShell — causes UTF-16LE corruption, see repo memory). One-off migration, not a recurring sync.
14. new-TEST, new-PROD: once new-DEV is validated, promote data forward using the existing DEV→TEST→PROD pattern (reference `scripts/sync/sync-dev-to-test.ps1` / `sync-dev-to-prod.ps1` logic) but targeting the new hostnames.
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
