#!/bin/bash
# =============================================================================
# Deploy Wikibase to TEST server
# Server : 178.105.195.111
# Domain : test-climatekg.semanticclimate.org
#
# Run from LOCAL (pipes over SSH):
#   ssh root@178.105.195.111 'bash -s' < scripts/deploy/deploy-test.sh
#
# Or run directly on the server:
#   cd /opt/wikibase && bash scripts/deploy/deploy-test.sh
# =============================================================================

export WIKIBASE_DOMAIN="test-climatekg.semanticclimate.org"
export WIKIBASE_ENV="test"
export COMPOSE_FILE="docker-compose.test.yml"
export ENV_TEMPLATE=".env.test.template"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/deploy.sh"
