#!/bin/bash
# =============================================================================
# Deploy Wikibase to TEST server
# Server : 46.224.66.24
# Domain : test-climatekg.semanticclimate.org
#
# Run from LOCAL (pipe wrapper + deploy.sh together over SSH):
#   cat scripts/deploy/deploy-test.sh scripts/deploy/deploy.sh | ssh root@46.224.66.24 'bash -s'
#
# Or run directly on the server (repo already cloned):
#   cd /opt/wikibase && bash scripts/deploy/deploy-test.sh
# =============================================================================

export WIKIBASE_DOMAIN="test-climatekg.semanticclimate.org"
export WIKIBASE_ENV="test"
export COMPOSE_FILE="docker-compose.test.yml"
export ENV_TEMPLATE=".env.test.template"

# When run directly on the server, source deploy.sh by its real path.
# When piped via 'bash -s', BASH_SOURCE[0] is empty/stdin — deploy.sh content
# follows inline from the cat command above; skip the source here.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "/dev/stdin" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/deploy.sh"
fi
