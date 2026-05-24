#!/bin/bash
# =============================================================================
# finish-deployment.sh
# Run this ONCE in a WSL terminal to complete all remaining server setup.
#
# Usage (from /mnt/c/Wikibase in WSL):
#   bash scripts/deploy/finish-deployment.sh
#
# What it does:
#   1. Starts a local ssh-agent and asks for your SSH passphrase ONCE
#   2. Bootstraps PROD server (178.105.222.174) from scratch
#   3. Repoints DEV server (178.104.156.88) to docker-compose.dev.yml
#   4. Obtains SSL certificates on TEST and PROD via Certbot
#   5. Retrieves and displays generated passwords for all 3 servers
# =============================================================================
set -euo pipefail

SSH_KEY_WIN="/mnt/c/Users/worthingtons/.ssh/id_rsa"
SSH_KEY_WSL="$HOME/.ssh/id_rsa"
ADMIN_EMAIL="simon.worthington@tib.eu"
REPO_DIR="/mnt/c/Wikibase"

DEV_HOST="178.104.156.88"
TEST_HOST="178.105.195.111"
PROD_HOST="178.105.222.174"

# Coloured output helpers
cyan()  { echo -e "\033[36m=== $* ===\033[0m"; }
green() { echo -e "\033[32m[OK] $*\033[0m"; }
red()   { echo -e "\033[31m[ERROR] $*\033[0m"; exit 1; }

# ---------------------------------------------------------------------------
# 1. SSH agent — copy key to WSL and load it
# ---------------------------------------------------------------------------
cyan "1/5  Setting up SSH agent"

# Copy key to WSL native filesystem (avoids NTFS permission issues)
mkdir -p "$HOME/.ssh"
cp "$SSH_KEY_WIN" "$SSH_KEY_WSL"
chmod 600 "$SSH_KEY_WSL"

eval "$(ssh-agent -s)"
ssh-add "$SSH_KEY_WSL"
green "SSH key loaded — passphrase will not be required again this session"

ssh_test() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$1" "echo ok" &>/dev/null && echo "reachable" || echo "UNREACHABLE"
}

# ---------------------------------------------------------------------------
# 2. Bootstrap PROD server
# ---------------------------------------------------------------------------
cyan "2/5  Bootstrapping PROD server ($PROD_HOST)"
if [ "$(ssh_test $PROD_HOST)" = "UNREACHABLE" ]; then
    red "Cannot reach PROD server at $PROD_HOST — check DNS/firewall"
fi

ssh "root@$PROD_HOST" 'bash -s' < "$REPO_DIR/scripts/deploy/deploy-prod.sh"
green "PROD bootstrap complete"

# ---------------------------------------------------------------------------
# 3. Redeploy DEV with docker-compose.dev.yml
# ---------------------------------------------------------------------------
cyan "3/5  Redeploying DEV server ($DEV_HOST) with docker-compose.dev.yml"
ssh "root@$DEV_HOST" "
    cd /opt/wikibase
    git pull --ff-only
    docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
"
green "DEV redeployed"

# ---------------------------------------------------------------------------
# 4. Obtain SSL certificates
# ---------------------------------------------------------------------------
cyan "4/5  Obtaining SSL certificates"

echo "  → TEST: test-climatekg.semanticclimate.org"
ssh "root@$TEST_HOST" \
    "certbot --nginx -d test-climatekg.semanticclimate.org \
     --non-interactive --agree-tos -m $ADMIN_EMAIL"
green "SSL issued for TEST"

echo "  → PROD: prod-climatekg.semanticclimate.org"
ssh "root@$PROD_HOST" \
    "certbot --nginx -d prod-climatekg.semanticclimate.org \
     --non-interactive --agree-tos -m $ADMIN_EMAIL"
green "SSL issued for PROD"

# ---------------------------------------------------------------------------
# 5. Collect generated passwords from every server
# ---------------------------------------------------------------------------
cyan "5/5  Collecting server credentials"

echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  IMPORTANT — save these credentials now (not stored in git)     │"
echo "├─────────────────────────────────────────────────────────────────┤"

echo "│  DEV  ($DEV_HOST)"
ssh "root@$DEV_HOST" "grep -E '^(DB_PASS|MW_ADMIN_PASS|MW_ADMIN_NAME|WIKIBASE_DOMAIN)' /opt/wikibase/.env" | sed 's/^/│    /'
echo "│"
echo "│  TEST  ($TEST_HOST)"
ssh "root@$TEST_HOST" "grep -E '^(DB_PASS|MW_ADMIN_PASS|MW_ADMIN_NAME|WIKIBASE_DOMAIN)' /opt/wikibase/.env" | sed 's/^/│    /'
echo "│"
echo "│  PROD  ($PROD_HOST)"
ssh "root@$PROD_HOST" "grep -E '^(DB_PASS|MW_ADMIN_PASS|MW_ADMIN_NAME|WIKIBASE_DOMAIN)' /opt/wikibase/.env" | sed 's/^/│    /'
echo "└─────────────────────────────────────────────────────────────────┘"

echo ""
echo "Add the DB_PASS values to C:\\Wikibase\\.env for the sync scripts:"
echo ""
DEV_DB=$(ssh "root@$DEV_HOST" "grep '^DB_PASS' /opt/wikibase/.env | cut -d= -f2")
TEST_DB=$(ssh "root@$TEST_HOST" "grep '^DB_PASS' /opt/wikibase/.env | cut -d= -f2")
PROD_DB=$(ssh "root@$PROD_HOST" "grep '^DB_PASS' /opt/wikibase/.env | cut -d= -f2")

echo "  DEV_DB_PASS=$DEV_DB"
echo "  TEST_DB_PASS=$TEST_DB"
echo "  PROD_DB_PASS=$PROD_DB"

# Write .env entries to a temp file so user can copy-paste to C:\Wikibase\.env
ENV_OUT="/mnt/c/Wikibase/backups/sync-passwords-$(date +%Y%m%d_%H%M%S).txt"
{
    echo "# Add these lines to C:\\Wikibase\\.env"
    echo "DEV_DB_PASS=$DEV_DB"
    echo "TEST_DB_PASS=$TEST_DB"
    echo "PROD_DB_PASS=$PROD_DB"
} > "$ENV_OUT"
green "Passwords also saved to backups/$(basename $ENV_OUT)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "\033[32m============================================================\033[0m"
echo -e "\033[32m  All servers are up!  Verify:\033[0m"
echo -e "\033[32m============================================================\033[0m"
echo ""
echo "  DEV   https://dev-climatekg.semanticclimate.org/wiki/Main_Page"
echo "  TEST  https://test-climatekg.semanticclimate.org/wiki/Main_Page"
echo "  PROD  https://prod-climatekg.semanticclimate.org/wiki/Main_Page"
echo ""
echo "Next: add the DB_PASS lines above to C:\\Wikibase\\.env"
echo "Then sync DEV content to TEST:  .\\scripts\\sync\\sync-dev-to-test.ps1"
echo ""
