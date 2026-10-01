#!/bin/bash
# =============================================================================
# Deploy Wikibase to IMPORT server (data-import staging sandbox)
# Server : climatekgdi21.service.tib.eu
# Domain : import-climatekg.tibwiki.io
#
# Sits behind the external TIB tibwiki.io TLS-terminating reverse proxy
# (catch-all forward to this box on port 80) — Certbot is skipped.
#
# Run from LOCAL (pipe wrapper + deploy.sh together over SSH):
#   cat scripts/deploy/deploy-import.sh scripts/deploy/deploy.sh | ssh worthingtons@climatekgdi21.service.tib.eu 'sudo bash -s'
#
# Or run directly on the server (repo already cloned):
#   cd /opt/wikibase && sudo bash scripts/deploy/deploy-import.sh
# =============================================================================

export WIKIBASE_DOMAIN="import-climatekg.tibwiki.io"
export WIKIBASE_ENV="import"
export COMPOSE_FILE="docker-compose.import.yml"
export ENV_TEMPLATE=".env.import.template"
export EXTERNAL_TLS_PROXY="true"
export BASIC_AUTH_ENABLED="true"
export BASIC_AUTH_USER="ckg"
export BASIC_AUTH_PASS="fairdata"

# When run directly on the server, source deploy.sh by its real path.
# When piped via 'bash -s', BASH_SOURCE[0] is empty/stdin — deploy.sh content
# follows inline from the cat command above; skip the source here.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/deploy.sh"
fi
