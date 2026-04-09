#!/bin/bash
# =============================================================================
# Wikibase Deployment Script for Hetzner VM
# Domain: dev-climatekg.semanticclimate.org
#
# Run this script on a fresh Ubuntu 24.04 Hetzner VM as root:
#   ssh root@<server-ip> 'bash -s' < deploy.sh
#
# Or copy the repo first and run from the server:
#   cd /opt/wikibase && bash deploy.sh
# =============================================================================
set -euo pipefail

DOMAIN="dev-climatekg.semanticclimate.org"
ADMIN_EMAIL="simon.worthington@tib.eu"
REPO_URL="https://github.com/mrchristian/Wikibase.git"
INSTALL_DIR="/opt/wikibase"

echo "==========================================="
echo "  Wikibase Deployment — $DOMAIN"
echo "==========================================="

# ------------------------------------------------------------------
# 1. System updates & prerequisites
# ------------------------------------------------------------------
echo "[1/7] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ------------------------------------------------------------------
# 2. Install Docker
# ------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
    echo "[2/7] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
else
    echo "[2/7] Docker already installed — $(docker --version)"
fi

# Verify docker compose plugin
docker compose version

# ------------------------------------------------------------------
# 3. Install Nginx & Certbot
# ------------------------------------------------------------------
echo "[3/7] Installing Nginx and Certbot..."
apt-get install -y -qq nginx certbot python3-certbot-nginx

# ------------------------------------------------------------------
# 4. Clone / update the repository
# ------------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "[4/7] Updating existing repository..."
    cd "$INSTALL_DIR"
    git pull --ff-only
else
    echo "[4/7] Cloning repository..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# ------------------------------------------------------------------
# 5. Create .env from template (if not already present)
# ------------------------------------------------------------------
if [ ! -f "$INSTALL_DIR/.env" ]; then
    echo "[5/7] Creating .env from .env.production template..."
    cp "$INSTALL_DIR/.env.production" "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    # Generate random passwords
    DB_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)
    MW_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)

    sed -i "s|CHANGE-ME-to-a-strong-random-password|${DB_PASS}|" "$INSTALL_DIR/.env"
    # The second occurrence is MW_ADMIN_PASS — sed replaces first match,
    # so we need a targeted replacement
    sed -i "s|^MW_ADMIN_PASS=.*|MW_ADMIN_PASS=${MW_PASS}|" "$INSTALL_DIR/.env"
    sed -i "s|^DB_PASS=.*|DB_PASS=${DB_PASS}|" "$INSTALL_DIR/.env"

    echo ""
    echo "  *** IMPORTANT: Note your generated credentials ***"
    echo "  DB_PASS:       $DB_PASS"
    echo "  MW_ADMIN_PASS: $MW_PASS"
    echo "  (Stored in $INSTALL_DIR/.env)"
    echo ""
else
    echo "[5/7] .env already exists — skipping credential generation"
fi

# ------------------------------------------------------------------
# 6. Configure Nginx reverse proxy
# ------------------------------------------------------------------
echo "[6/7] Configuring Nginx reverse proxy..."

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

    # SPARQL proxy endpoint (used by the query UI)
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

nginx -t
systemctl reload nginx

# ------------------------------------------------------------------
# 7. Firewall
# ------------------------------------------------------------------
echo "[7/7] Configuring firewall..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ------------------------------------------------------------------
# Start the stack
# ------------------------------------------------------------------
echo ""
echo "Starting Wikibase stack..."
cd "$INSTALL_DIR"
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d

echo ""
echo "==========================================="
echo "  Deployment started!"
echo "==========================================="
echo ""
echo "Containers are initializing (this takes 3–5 minutes)."
echo "Monitor with:  docker compose logs -f"
echo ""
echo "Once the wiki responds at http://$DOMAIN, run:"
echo "  certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL"
echo ""
echo "Then verify at: https://$DOMAIN/wiki/Main_Page"
echo "Query service:  https://$DOMAIN/query/"
echo ""
