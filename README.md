# Wikibase Docker Stack

A complete Wikibase environment running on Docker Desktop, including the SPARQL query service.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running on Windows

## Loading the Stack in Docker Desktop

### Option 1 - From the command line (recommended)

Open a PowerShell terminal in the C:\Wikibase folder and run:

```powershell
docker compose up -d
```

Docker Desktop will automatically detect the running containers. Open Docker Desktop and click **Containers** in the left sidebar - you will see a **wikibase** stack with all 5 services listed.

### Option 2 - From the Docker Desktop GUI

1. Open **Docker Desktop**
2. Go to the **Containers** view (left sidebar, top icon)
3. If the stack is not yet running, start it from the terminal as shown above
4. Once running, click the **wikibase** stack row to expand it and see all services
5. Click any service name to view its logs, inspect environment variables, or open a terminal inside the container
6. Use the start/stop/restart buttons on each container row to manage individual services
7. Port links (e.g. 8080:80) are clickable - click them to open the service in your browser

### Viewing volumes in Docker Desktop

1. Click **Volumes** in the left sidebar
2. You will see three volumes: wikibase_data, wikibase_config, and wdqs_data
3. Click any volume to inspect its contents and size

### First startup

The first startup takes several minutes:
1. MariaDB initializes the database (~30 seconds)
2. Wikibase runs the MediaWiki installer (~2-4 minutes)
3. Blazegraph starts and the updater begins syncing (~1 minute)

Monitor progress in Docker Desktop by clicking the **wikibase** stack and watching container status change from **Starting** to **Running (healthy)**.

## Services

| Service | Image | Port | Description |
|---------|-------|------|-------------|
| **wikibase** | wikibase/wikibase:mw1.45.0 | localhost:8080 | MediaWiki + Wikibase |
| **mariadb** | mariadb:10.11 | - | Database backend |
| **wdqs** | wikibase/wdqs:2 | localhost:9999 | Blazegraph SPARQL endpoint |
| **wdqs-updater** | wikibase/wdqs:2 | - | Syncs Wikibase changes to WDQS |
| **wdqs-frontend** | Custom (see Dockerfile) | localhost:8081 | SPARQL query UI |
| **wikibase-sitelinks-init** | wikibase/wikibase:mw1.45.0 | - | One-shot: registers sitelinks config |

## Endpoints

| URL | Purpose |
|-----|---------|
| http://localhost:8080 | Wikibase wiki |
| http://localhost:8080/wiki/Special:CreateItem | Create a new item |
| http://localhost:8080/wiki/Special:NewProperty | Create a new property |
| http://localhost:8081 | SPARQL query UI |
| http://localhost:9999/bigdata/namespace/wdq/sparql | SPARQL API (direct) |
| http://localhost:8081/proxy/sparql | SPARQL API (via nginx proxy) |

## URI format in WDQS

WDQS queries use entity URIs, not wiki page URLs.

- Use http://localhost:8080/entity/Q1 in SPARQL patterns
- Do not use http://localhost:8080/wiki/Item:Q1 in SPARQL patterns

Quick check:

```sparql
ASK { <http://localhost:8080/entity/Q1> ?p ?o }    # True
ASK { <http://localhost:8080/wiki/Item:Q1> ?p ?o } # False
```
## Credentials

| Field | Value |
|-------|-------|
| Admin username | admin |
| Admin password | adminpass123! |

## SPARQL Queries

### Using the query UI

Open http://localhost:8081, enter a query, and click the blue play button.

### Using the helper script

```powershell
# Basic test - is there any data?
.\query-sparql.ps1 -Query 'ASK { ?s ?p ?o }'

# Sample triples
.\query-sparql.ps1 -Query 'SELECT * WHERE { ?s ?p ?o } LIMIT 10'

# Count all triples
.\query-sparql.ps1 -Query 'SELECT (COUNT(*) AS ?count) WHERE { ?s ?p ?o }'

# Query a specific item
.\query-sparql.ps1 -Query 'SELECT ?p ?o WHERE { <http://localhost:8080/entity/Q1> ?p ?o . } LIMIT 10'
```

### Using the API directly (PowerShell)

```powershell
$query = 'SELECT * WHERE { ?s ?p ?o } LIMIT 10'
$encoded = [uri]::EscapeDataString($query)
$url = "http://localhost:9999/bigdata/namespace/wdq/sparql?query=$encoded"
$response = Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{Accept='application/sparql-results+json'}
($response.Content | ConvertFrom-Json).results.bindings | ConvertTo-Json -Depth 5
```

### Using curl

```bash
curl -G http://localhost:9999/bigdata/namespace/wdq/sparql \
  --data-urlencode 'query=SELECT * WHERE { ?s ?p ?o } LIMIT 10' \
  -H 'Accept: application/sparql-results+json'
```

## Volumes

| Volume | Mount Point | Purpose |
|--------|-------------|---------|
| wikibase_data | /var/lib/mysql | MariaDB database files |
| wikibase_config | /config | Wikibase configuration (LocalSettings.php) |
| wdqs_data | /wdqs/data | Blazegraph triplestore data |

## Files

| File | Purpose |
|------|---------|
| LocalSettings.sitelinks.php | PHP settings enabling sitelinks |
| sites.xml | Site definition imported into the sites table |
| init-sitelinks.sh | Initialization script for sitelinks setup |
| docker-compose.yml | Service definitions |
| Dockerfile.wdqs-frontend | Custom WDQS frontend image build |
| wdqs-frontend-nginx.conf | Nginx config template with SPARQL proxy and i18n alias |
| wdqs-custom-config.json | Frontend SPARQL endpoint configuration |
| query-sparql.ps1 | PowerShell helper for SPARQL queries |

## Sitelinks

Sitelinks allow you to link MediaWiki pages to Wikibase items. The local wiki is registered with site ID `mywiki`.

### First-time setup

Sitelinks are configured automatically on first startup. The `wikibase-sitelinks-init` container:

1. Copies `LocalSettings.sitelinks.php` into the config volume
2. Adds a `LocalSettings.d` autoloader to `LocalSettings.php`
3. Imports `sites.xml` into the MediaWiki sites table

After the init container finishes, restart Wikibase to load the new PHP settings:

```powershell
docker compose restart wikibase
```

### Adding a sitelink to an item

1. Open an item page (e.g. http://localhost:8080/wiki/Item:Q1)
2. Scroll to the **Sitelinks** section
3. Click **add** under the **mywiki** group
4. Enter `mywiki` as the site and the page name (e.g. `Main Page`)
5. Save

The linked page will now show a link back to the Wikibase item in its sidebar.

### Re-running the init

The init script is idempotent. To re-run it:

```powershell
docker compose up wikibase-sitelinks-init
docker compose restart wikibase
```

## Common Operations

```powershell
# Start the stack
docker compose up -d

# Check status
docker compose ps

# Stop all services
docker compose down

# View logs for a service
docker compose logs --tail 50 wikibase
docker compose logs --tail 50 wdqs-updater

# Restart a single service
docker compose restart wdqs-frontend

# Rebuild the custom frontend after editing config files
docker compose build --no-cache wdqs-frontend
docker compose up -d --force-recreate wdqs-frontend

# Reset WDQS data (re-sync from Wikibase)
docker compose stop wdqs wdqs-updater
docker compose rm -f wdqs wdqs-updater
docker volume rm wdqs_data
docker compose up -d wdqs wdqs-updater

# Destroy everything (including data)
docker compose down -v
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Wikibase returns 500 | MariaDB not ready yet | Wait for healthcheck; check docker compose logs mariadb |
| SPARQL query returns 0 rows | Updater hasn't synced yet | Check docker compose logs wdqs-updater; wait a few minutes after creating items |
| SPARQL query for Item:Q1 returns false/empty | Using wiki page URL instead of entity URI | Use http://localhost:8080/entity/Q1 in queries, not http://localhost:8080/wiki/Item:Q1 |
| WDQS frontend query error | CORS if hitting port 9999 directly | Frontend uses /proxy/sparql - ensure the custom image is built |
| i18n 404 errors in frontend | Missing jquery.uls alias | Rebuild with docker compose build wdqs-frontend |
| Container keeps restarting | Dependency not healthy | Run docker compose ps and check healthcheck status |
| Stack not visible in Docker Desktop | Containers not running | Run docker compose up -d from the C:\Wikibase folder |