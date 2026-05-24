#!/bin/bash
# =============================================================================
# Deploy Wikibase to PRODUCTION server
# Server : 178.105.222.174
# Domain : prod-climatekg.semanticclimate.org
#
# Run from LOCAL (pipes over SSH):
#   ssh root@178.105.222.174 'bash -s' < scripts/deploy/deploy-prod.sh
#
# Or run directly on the server:
#   cd /opt/wikibase && bash scripts/deploy/deploy-prod.sh
# =============================================================================

export WIKIBASE_DOMAIN="prod-climatekg.semanticclimate.org"
export WIKIBASE_ENV="prod"
export COMPOSE_FILE="docker-compose.prod.yml"
export ENV_TEMPLATE=".env.production"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/deploy.sh"
