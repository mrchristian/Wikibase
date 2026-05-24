#!/bin/bash
# =============================================================================
# Deploy Wikibase to DEV server
# Server : 178.104.156.88
# Domain : dev-climatekg.semanticclimate.org
#
# Run from LOCAL (pipes over SSH):
#   ssh root@178.104.156.88 'bash -s' < scripts/deploy/deploy-dev.sh
#
# Or run directly on the server:
#   cd /opt/wikibase && bash scripts/deploy/deploy-dev.sh
# =============================================================================

export WIKIBASE_DOMAIN="dev-climatekg.semanticclimate.org"
export WIKIBASE_ENV="dev"
export COMPOSE_FILE="docker-compose.dev.yml"
export ENV_TEMPLATE=".env.dev.template"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/deploy.sh"
