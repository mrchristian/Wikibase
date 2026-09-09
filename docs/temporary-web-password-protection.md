# Temporary Web Password Protection (DEV, TEST, PROD)

This document records the temporary web access protection applied on 2026-09-09 and how to maintain or remove it.

## Purpose

Keep the three public environments off the open web while MediaWiki and Wikibase are being prepared.

## Credentials in Use

- Username:  
- Password:  

## What Was Applied (2026-09-09)

Protection was applied at the host Nginx layer on all servers by:

1. Creating `/etc/nginx/.htpasswd-wikibase` with an Apache MD5 hash for the password.
2. Adding these directives in `/etc/nginx/sites-available/wikibase` inside the `server { ... }` block:

```nginx
auth_basic "Restricted";
auth_basic_user_file /etc/nginx/.htpasswd-wikibase;
```

3. Running `nginx -t` and `systemctl reload nginx`.

### Verification Results

- `https://dev-climatekg.semanticclimate.org/wiki/Main_Page` -> `401` without auth, `200` with valid Basic Auth credentials
- `https://test-climatekg.semanticclimate.org/wiki/Main_Page` -> `401` without auth, `200` with valid Basic Auth credentials
- `https://prod-climatekg.semanticclimate.org/wiki/Main_Page` -> `401` without auth, `200` with valid Basic Auth credentials

## Deployment Script Support (Added)

`scripts/deploy/deploy.sh` now supports optional Basic Auth via environment variables:

- `BASIC_AUTH_ENABLED` (`true|false`, default `false`)
- `BASIC_AUTH_USER`
- `BASIC_AUTH_PASS`

When enabled, the script automatically:

1. Writes `/etc/nginx/.htpasswd-wikibase`.
2. Injects Nginx `auth_basic` directives.
3. Keeps behavior disabled by default unless explicitly enabled.

## How To Deploy With Password Protection Enabled

Example for DEV (run from local repo root):

```bash
cat scripts/deploy/deploy-dev.sh scripts/deploy/deploy.sh \
  | ssh root@178.104.156.88 \
    "BASIC_AUTH_ENABLED=true BASIC_AUTH_USER='<username>' BASIC_AUTH_PASS='<password>' bash -s"
```

Repeat with `deploy-test.sh` and `deploy-prod.sh` for TEST and PROD hosts.

## How To Remove Password Protection Later

Run on each host (replace host IP as needed):

```bash
ssh -i ~/.ssh/id_wikibase_sync root@178.104.156.88 "\
  sed -i '/auth_basic \"Restricted\";/d;/auth_basic_user_file \/etc\/nginx\/.htpasswd-wikibase;/d' /etc/nginx/sites-available/wikibase && \
  rm -f /etc/nginx/.htpasswd-wikibase && \
  nginx -t && systemctl reload nginx"
```

Hosts:

- DEV: `178.104.156.88`
- TEST: `46.224.66.24`
- PROD: `178.105.222.174`

## Prevent Re-Enabling During Future Deployments

Leave `BASIC_AUTH_ENABLED` unset (or set to `false`) when running deploy scripts.

If a server still has old auth lines from a previous manual edit, run the removal command once to clean it.