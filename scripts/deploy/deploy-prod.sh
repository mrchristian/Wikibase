#!/bin/bash
# =============================================================================
# Deploy Wikibase to PRODUCTION server
# Server : 178.105.222.174
# Domain : prod-climatekg.semanticclimate.org
#
# Run from LOCAL (pipe wrapper + deploy.sh together over SSH):
#   cat scripts/deploy/deploy-prod.sh scripts/deploy/deploy.sh | ssh root@178.105.222.174 'bash -s'
#
# Or run directly on the server (repo already cloned):
#   cd /opt/wikibase && bash scripts/deploy/deploy-prod.sh
# =============================================================================

export WIKIBASE_DOMAIN="prod-climatekg.semanticclimate.org"
export WIKIBASE_ENV="prod"
export COMPOSE_FILE="docker-compose.prod.yml"
export ENV_TEMPLATE=".env.production"

# When run directly on the server, source deploy.sh by its real path.
# When piped via 'bash -s', BASH_SOURCE[0] is empty/stdin — deploy.sh content
# follows inline from the cat command above; skip the source here.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/deploy.sh"
fi
