# Deploying Wikibase to a Hetzner Cloud VM

This guide walks through deploying the Wikibase Docker stack to a Hetzner Cloud VM at **`dev-climatekg.semanticclimate.org`** with HTTPS.

## Prerequisites

- A [Hetzner Cloud](https://www.hetzner.com/cloud) account
- DNS access for `semanticclimate.org`
- An SSH key pair for server access

## Production Files

| File | Purpose |
|------|---------|
| `docker-compose.prod.yml` | Overrides `docker-compose.yml` for production (binds ports to 127.0.0.1, sets domain) |
| `.env.production` | Template for credentials and domain — copy to `.env` on the server |
| `sites.prod.xml` | Sitelinks XML with the production domain |
| `wdqs-custom-config.prod.json` | Query service config pointing to production URLs |
| `deploy.sh` | Automated server setup script (Docker, Nginx, firewall, stack start) |

## Quick Deploy (Automated)

Once the VM is provisioned and DNS is set, run:
```bash
ssh root@<server-ip> 'bash -s' < deploy.sh
```

This installs Docker, Nginx, clones the repo, generates random passwords, and starts everything. Then obtain SSL:
```bash
ssh root@<server-ip>
certbot --nginx -d dev-climatekg.semanticclimate.org --non-interactive --agree-tos -m simon.worthington@tib.eu
```

---

## Step-by-Step Deploy (Manual)

## 1. Provision the VM

1. Log in to the Hetzner Cloud Console.
2. Create a new server:
   - **Image**: Ubuntu 24.04
   - **Type**: CX22 (2 vCPU / 4 GB RAM) or larger — this stack runs 6 containers including Blazegraph, which benefits from memory
   - **Location**: Choose the region closest to your users (e.g. Falkenstein or Nuremberg for EU)
   - **SSH Key**: Add your public key
   - **Name**: e.g. `wikibase-prod`
3. Note the server's public IPv4 address.

## 2. Point Your Domain

In the DNS for `semanticclimate.org`, create an **A record**:

| Type | Name | Value | TTL |
|------|------|-------|-----|
| A | `dev-climatekg` | `<server-ip>` | 300 |

Wait for DNS propagation before proceeding:
```bash
nslookup dev-climatekg.semanticclimate.org
```

## 3. Install Docker on the VM

SSH into the server and install Docker:

```bash
ssh root@<server-ip>

# Install Docker
curl -fsSL https://get.docker.com | sh

# Verify
docker --version
docker compose version
```

## 4. Clone the Repository

```bash
cd /opt
git clone https://github.com/mrchristian/Wikibase.git wikibase
cd wikibase
```

## 5. Create the Environment File

Copy the production template and set strong passwords:

```bash
cp .env.production .env
chmod 600 .env

# Generate and set random passwords
DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
MW_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
sed -i "s|^DB_PASS=.*|DB_PASS=${DB_PASS}|" .env
sed -i "s|^MW_ADMIN_PASS=.*|MW_ADMIN_PASS=${MW_PASS}|" .env

echo "DB_PASS: $DB_PASS"
echo "MW_ADMIN_PASS: $MW_PASS"
```

> **Save these credentials securely!**

## 6. Configuration (Already Done)

Production configuration is handled by the override files — **no need to edit `docker-compose.yml`**:

- `docker-compose.prod.yml` overrides all `localhost` references with `$WIKIBASE_DOMAIN` from `.env`
- `sites.prod.xml` has the production domain for sitelinks
- `wdqs-custom-config.prod.json` points the query UI to production URLs
- Ports are bound to `127.0.0.1` so only Nginx can reach them

See [deployment-guide.md](deployment-guide.md) for the full sitelinks configuration checklist.

## 7. Set Up Nginx Reverse Proxy with SSL

Install Nginx and Certbot on the host (outside Docker):

```bash
apt update
apt install -y nginx certbot python3-certbot-nginx
```

Create an Nginx site configuration:

```bash
cat > /etc/nginx/sites-available/wikibase << 'NGINX'
server {
    listen 80;
    server_name dev-climatekg.semanticclimate.org;

    client_max_body_size 64m;

    # Main wiki
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }

    # SPARQL query UI
    location /query/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # SPARQL proxy endpoint
    location /query/proxy/sparql {
        proxy_pass http://127.0.0.1:9999/bigdata/namespace/wdq/sparql;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/wikibase /etc/nginx/sites-enabled/wikibase
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
```

Obtain an SSL certificate:

```bash
certbot --nginx -d dev-climatekg.semanticclimate.org --non-interactive --agree-tos -m simon.worthington@tib.eu
```

Certbot will automatically update the Nginx config to redirect HTTP to HTTPS and add the certificate paths.

## 8. Configure the Firewall

```bash
# Allow SSH, HTTP, and HTTPS only
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

> **Note**: Do not expose ports 8080, 8081, or 9999 publicly. Nginx proxies external traffic to these internal ports.

## 9. Start the Stack

```bash
cd /opt/wikibase
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

Monitor startup progress:

```bash
docker compose logs -f
```

First startup takes several minutes:
1. MariaDB initializes (~30 seconds)
2. Wikibase runs the MediaWiki installer (~2–4 minutes)
3. Blazegraph starts and the updater begins syncing (~1 minute)
4. The sitelinks init container registers sitelinks and exits

## 10. Verify the Deployment

| Check | URL |
|-------|-----|
| Wiki main page | `https://dev-climatekg.semanticclimate.org/wiki/Main_Page` |
| Create an item | `https://dev-climatekg.semanticclimate.org/wiki/Special:CreateItem` |
| SPARQL query UI | `https://dev-climatekg.semanticclimate.org/query/` |
| Admin login | `https://dev-climatekg.semanticclimate.org/wiki/Special:UserLogin` |

## Post-Deployment

### Automatic SSL Renewal

Certbot installs a systemd timer for auto-renewal. Verify it is active:

```bash
systemctl status certbot.timer
```

### Backups

Back up the Docker volumes regularly:

```bash
# Database dump
docker exec wikibase-mariadb sh -c 'exec mysqldump -u wikibase -p"$MYSQL_PASSWORD" my_wiki' > backup.sql

# Volume snapshots (Hetzner also offers server snapshots)
docker run --rm -v wikibase_data:/data -v $(pwd):/backup alpine tar czf /backup/wikibase_data.tar.gz /data
docker run --rm -v wdqs_data:/data -v $(pwd):/backup alpine tar czf /backup/wdqs_data.tar.gz /data
```

### Updates

```bash
cd /opt/wikibase
git pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

---

## Summary Checklist

1. [ ] Provision Hetzner CX22+ VM (Ubuntu 24.04)
2. [ ] Create DNS A record: `dev-climatekg` → `<server-ip>`
3. [ ] Run `deploy.sh` on the VM (or follow steps 3–9 manually)
4. [ ] Verify wiki is accessible at `http://dev-climatekg.semanticclimate.org`
5. [ ] Run `certbot` to obtain SSL certificate
6. [ ] Verify HTTPS: wiki, query service, sitelinks all work
7. [ ] Save `.env` credentials securely
8. [ ] Set up backups
