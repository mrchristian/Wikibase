#!/bin/bash
# =============================================================================
# Deploy Wikibase to the NEW DEV server (replaces the old Hetzner DEV box)
# Server : climatekg01.develop.service.tib.eu
# Domain : dev-climatekg.tibwiki.io
#
# Sits behind the external TIB tibwiki.io TLS-terminating reverse proxy
# (catch-all forward to this box on port 80) — Certbot is skipped.
#
# TEMPORARY wrapper used during the staged validation window. The existing
# scripts/deploy/deploy-dev.sh still targets the OLD, currently-live DEV box
# (dev-climatekg.semanticclimate.org) and is left untouched until cutover is
# approved — do not merge/rename these until then.
#
# Run from LOCAL (pipe wrapper + deploy.sh together over SSH):
#   cat scripts/deploy/deploy-dev-new.sh scripts/deploy/deploy.sh | ssh worthingtons@climatekg01.develop.service.tib.eu 'sudo bash -s'
#
# Or run directly on the server (repo already cloned):
#   cd /opt/wikibase && sudo bash scripts/deploy/deploy-dev-new.sh
# =============================================================================

export WIKIBASE_DOMAIN="dev-climatekg.tibwiki.io"
export WIKIBASE_ENV="dev"
export COMPOSE_FILE="docker-compose.dev.yml"
export ENV_TEMPLATE=".env.dev.template"
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
