#!/bin/bash
# =============================================================================
# Deploy Wikibase to DEV server
# Server : 178.104.156.88
# Domain : dev-climatekg.semanticclimate.org
#
# Run from LOCAL (pipe wrapper + deploy.sh together over SSH):
#   cat scripts/deploy/deploy-dev.sh scripts/deploy/deploy.sh | ssh root@178.104.156.88 'bash -s'
#
# Or run directly on the server (repo already cloned):
#   cd /opt/wikibase && bash scripts/deploy/deploy-dev.sh
# =============================================================================

export WIKIBASE_DOMAIN="dev-climatekg.semanticclimate.org"
export WIKIBASE_ENV="dev"
export COMPOSE_FILE="docker-compose.dev.yml"
export ENV_TEMPLATE=".env.dev.template"

# When run directly on the server, source deploy.sh by its real path.
# When piped via 'bash -s', BASH_SOURCE[0] is empty/stdin — deploy.sh content
# follows inline from the cat command above; skip the source here.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/deploy.sh"
fi
