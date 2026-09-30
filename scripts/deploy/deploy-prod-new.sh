#!/bin/bash
# =============================================================================
# Deploy Wikibase to the NEW PROD server (replaces the old Hetzner PROD box)
# Server : climatekg21.service.tib.eu
# Domain : climatekg.tibwiki.io
#
# Sits behind the external TIB tibwiki.io TLS-terminating reverse proxy
# (catch-all forward to this box on port 80) — Certbot is skipped.
#
# TEMPORARY wrapper used during the staged validation window. The existing
# scripts/deploy/deploy-prod.sh still targets the OLD, currently-live PROD box
# (prod-climatekg.semanticclimate.org) and is left untouched until cutover is
# approved — do not merge/rename these until then.
#
# Run from LOCAL (pipe wrapper + deploy.sh together over SSH):
#   cat scripts/deploy/deploy-prod-new.sh scripts/deploy/deploy.sh | ssh worthingtons@climatekg21.service.tib.eu 'sudo bash -s'
#
# Or run directly on the server (repo already cloned):
#   cd /opt/wikibase && sudo bash scripts/deploy/deploy-prod-new.sh
# =============================================================================

export WIKIBASE_DOMAIN="climatekg.tibwiki.io"
export WIKIBASE_ENV="prod"
export COMPOSE_FILE="docker-compose.prod.yml"
export ENV_TEMPLATE=".env.production"
export EXTERNAL_TLS_PROXY="true"

# When run directly on the server, source deploy.sh by its real path.
# When piped via 'bash -s', BASH_SOURCE[0] is empty/stdin — deploy.sh content
# follows inline from the cat command above; skip the source here.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/deploy.sh"
fi
