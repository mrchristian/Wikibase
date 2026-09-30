#!/bin/bash
# =============================================================================
# Wikibase Generic Deployment Script for Hetzner VM
#
# This script is not called directly. Use one of the environment wrappers:
#   scripts/deploy/deploy-dev.sh
#   scripts/deploy/deploy-test.sh
#   scripts/deploy/deploy-prod.sh
#
# Each wrapper sets the required variables and then sources this script.
#
# Direct invocation (from a wrapper piped over SSH):
#   ssh root@<server-ip> 'bash -s' < scripts/deploy/deploy-dev.sh
#
# Required variables (set by wrapper before sourcing):
#   WIKIBASE_DOMAIN   — public hostname (e.g. test-climatekg.semanticclimate.org)
#   WIKIBASE_ENV      — environment label: dev | test | prod
#   COMPOSE_FILE      — compose override filename (e.g. docker-compose.test.yml)
#   ENV_TEMPLATE      — .env template filename   (e.g. .env.test.template)
#
# Optional variables:
#   EXTERNAL_TLS_PROXY — set to true when the box sits behind an external
#                        TLS-terminating reverse proxy (e.g. the TIB tibwiki.io
#                        front door) that forwards all paths to this box on
#                        port 80. Skips Certbot install/cert issuance and only
#                        opens ports 22/80 in the firewall — this box never
#                        needs to terminate TLS itself.
# =============================================================================
set -euo pipefail

EXTERNAL_TLS_PROXY="${EXTERNAL_TLS_PROXY:-false}"
EXTERNAL_TLS_PROXY_ON=0
case "${EXTERNAL_TLS_PROXY,,}" in
    1|true|yes|on)
        EXTERNAL_TLS_PROXY_ON=1
        ;;
esac

: "${WIKIBASE_DOMAIN:?Variable WIKIBASE_DOMAIN must be set by the calling wrapper.}"
: "${WIKIBASE_ENV:?Variable WIKIBASE_ENV must be set by the calling wrapper.}"
: "${COMPOSE_FILE:?Variable COMPOSE_FILE must be set by the calling wrapper.}"
: "${ENV_TEMPLATE:?Variable ENV_TEMPLATE must be set by the calling wrapper.}"

# Optional temporary web protection (HTTP Basic Auth)
# Set BASIC_AUTH_ENABLED=true and provide BASIC_AUTH_USER/BASIC_AUTH_PASS
# to protect the site at the Nginx layer.
BASIC_AUTH_ENABLED="${BASIC_AUTH_ENABLED:-false}"
BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"
BASIC_AUTH_PASS="${BASIC_AUTH_PASS:-}"
BASIC_AUTH_FILE="/etc/nginx/.htpasswd-wikibase"

BASIC_AUTH_ON=0
case "${BASIC_AUTH_ENABLED,,}" in
    1|true|yes|on)
        BASIC_AUTH_ON=1
        ;;
esac

if [ "$BASIC_AUTH_ON" -eq 1 ]; then
    if [ -z "$BASIC_AUTH_USER" ] || [ -z "$BASIC_AUTH_PASS" ]; then
        echo "[error] BASIC_AUTH_ENABLED is true but BASIC_AUTH_USER/BASIC_AUTH_PASS is missing"
        exit 1
    fi
fi

ADMIN_EMAIL="simon.worthington@tib.eu"
REPO_URL="https://github.com/mrchristian/Wikibase.git"
INSTALL_DIR="/opt/wikibase"

echo "==========================================="
echo "  Wikibase Deployment [$WIKIBASE_ENV] — $WIKIBASE_DOMAIN"
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
# 3. Install Nginx (& Certbot, unless TLS is terminated externally)
# ------------------------------------------------------------------
if [ "$EXTERNAL_TLS_PROXY_ON" -eq 1 ]; then
    echo "[3/7] Installing Nginx (Certbot skipped — EXTERNAL_TLS_PROXY is enabled)..."
    apt-get install -y -qq nginx
else
    echo "[3/7] Installing Nginx and Certbot..."
    apt-get install -y -qq nginx certbot python3-certbot-nginx
fi

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
    echo "[5/7] Creating .env from $ENV_TEMPLATE template..."
    cp "$INSTALL_DIR/$ENV_TEMPLATE" "$INSTALL_DIR/.env"
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

AUTH_DIRECTIVES=""
if [ "$BASIC_AUTH_ON" -eq 1 ]; then
    echo "      Temporary Basic Auth is enabled for $WIKIBASE_DOMAIN"
    AUTH_HASH=$(openssl passwd -apr1 "$BASIC_AUTH_PASS")
    printf '%s:%s\n' "$BASIC_AUTH_USER" "$AUTH_HASH" > "$BASIC_AUTH_FILE"
    chmod 640 "$BASIC_AUTH_FILE"
    chown root:www-data "$BASIC_AUTH_FILE" 2>/dev/null || true
    AUTH_DIRECTIVES="    auth_basic \"Restricted\";
    auth_basic_user_file $BASIC_AUTH_FILE;

"
else
    echo "      Basic Auth is disabled"
fi

cat > /etc/nginx/sites-available/wikibase << NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${WIKIBASE_DOMAIN};

    client_max_body_size 64m;

${AUTH_DIRECTIVES}

    # Main wiki
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }

    # SPARQL query UI
    location /query/ {
        proxy_pass http://127.0.0.1:8081/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # SPARQL proxy endpoint (used by the query UI)
    location /query/proxy/sparql {
        proxy_pass http://127.0.0.1:9999/bigdata/namespace/wdq/sparql;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
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
if [ "$EXTERNAL_TLS_PROXY_ON" -eq 0 ]; then
    ufw allow 443/tcp
fi
ufw --force enable

# ------------------------------------------------------------------
# Start the stack
# ------------------------------------------------------------------
echo ""
echo "Starting Wikibase stack [$WIKIBASE_ENV]..."
cd "$INSTALL_DIR"
docker compose -f docker-compose.yml -f "$COMPOSE_FILE" up -d --build

echo ""
echo "==========================================="
echo "  Deployment started! [$WIKIBASE_ENV]"
echo "==========================================="
echo ""
echo "Containers are initializing (this takes 3–5 minutes)."
echo "Monitor with:  docker compose logs -f"
echo ""
if [ "$BASIC_AUTH_ON" -eq 1 ]; then
    echo "Basic Auth is active for this deployment (user: $BASIC_AUTH_USER)"
    echo ""
fi
if [ "$EXTERNAL_TLS_PROXY_ON" -eq 1 ]; then
    echo "TLS is terminated by the external reverse proxy — no local Certbot step needed."
    echo "Once the wiki responds at http://$WIKIBASE_DOMAIN, verify end-to-end through the"
    echo "external proxy at: https://$WIKIBASE_DOMAIN/wiki/Main_Page"
    echo "Query service:  https://$WIKIBASE_DOMAIN/query/"
else
    echo "Once the wiki responds at http://$WIKIBASE_DOMAIN, run:"
    echo "  certbot --nginx -d $WIKIBASE_DOMAIN --non-interactive --agree-tos -m $ADMIN_EMAIL"
    echo ""
    echo "Then verify at: https://$WIKIBASE_DOMAIN/wiki/Main_Page"
    echo "Query service:  https://$WIKIBASE_DOMAIN/query/"
fi
echo ""
