#!/usr/bin/env bash
# =============================================================================
# Switch a server's /opt/wikibase clone so 'origin' is TIB GitLab
# (the GitHub remote is kept as 'github', as a backup mirror).
#
# Run ON the server, as root (deploy.sh and the runbook pull as root):
#   cd /opt/wikibase && sudo bash scripts/deploy/switch-git-remote.sh
#   sudo bash scripts/deploy/switch-git-remote.sh <other-url>
#
# SSH URL (default): uses a read-only deploy key at /root/.ssh/id_ed25519_ckg_deploy.
# If the key does not exist it is generated (no passphrase) and the PUBLIC key is
# printed; add it in GitLab -> Settings -> Repository -> Deploy keys (read-only),
# then re-run this script.
#
# HTTPS URL: pass a URL that already carries a read-only deploy token, e.g.
#   https://<deploy-user>:<token>@git.tib.eu/OSL/climate-knowledge-graph/climatekg-deploy.git
# (the token is stored in .git/config, which is root-only readable here).
#
# On any failure the previous 'origin' is restored. Nothing is pulled.
# =============================================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/wikibase}"
TIB_URL="${1:-${TIB_GIT_URL:-git@git.tib.eu:OSL/climate-knowledge-graph/climatekg-deploy.git}}"
TIB_HOST="git.tib.eu"
KEY="/root/.ssh/id_ed25519_ckg_deploy"
BRANCH="${GIT_BRANCH:-master}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[error] Run as root (sudo bash $0)" >&2
    exit 1
fi
if [ ! -d "$INSTALL_DIR/.git" ]; then
    echo "[error] $INSTALL_DIR is not a git clone" >&2
    exit 1
fi
cd "$INSTALL_DIR"

OLD_URL="$(git remote get-url origin)"
echo "Current origin : $(echo "$OLD_URL" | sed -E 's#(https?://)[^@/]+@#\1***@#')"
echo "Current commit : $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
echo "Target origin  : $(echo "$TIB_URL" | sed -E 's#(https?://)[^@/]+@#\1***@#')"

if [ -n "$(git status --porcelain)" ]; then
    echo "[warn] Working tree has local changes (not touched by this script):"
    git status --short
fi

# ------------------------------------------------------------------
# SSH setup (only for git@ / ssh:// URLs)
# ------------------------------------------------------------------
case "$TIB_URL" in
    git@*|ssh://*)
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh

        if [ ! -f "$KEY" ]; then
            echo "Generating deploy key $KEY ..."
            ssh-keygen -t ed25519 -N "" -C "climatekg-deploy@$(hostname)" -f "$KEY" >/dev/null
            echo ""
            echo "=============================================================="
            echo " Add this PUBLIC key as a READ-ONLY deploy key in GitLab"
            echo " (climatekg-deploy -> Settings -> Repository -> Deploy keys),"
            echo " then re-run this script:"
            echo ""
            cat "$KEY.pub"
            echo "=============================================================="
            exit 2
        fi

        if ! grep -q "^Host $TIB_HOST\$" /root/.ssh/config 2>/dev/null; then
            cat >> /root/.ssh/config <<EOF

Host $TIB_HOST
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
            chmod 600 /root/.ssh/config
        fi
        ;;
esac

# ------------------------------------------------------------------
# Verify access BEFORE changing the remote
# ------------------------------------------------------------------
echo "Checking access to TIB git ..."
if ! git ls-remote --exit-code "$TIB_URL" "refs/heads/$BRANCH" >/tmp/ckg-lsremote.txt 2>/tmp/ckg-lsremote.err; then
    echo "[error] Cannot read refs/heads/$BRANCH from the TIB remote:" >&2
    cat /tmp/ckg-lsremote.err >&2
    echo "Check: network reachability of $TIB_HOST, deploy key added (read-only), branch name (GIT_BRANCH=$BRANCH)." >&2
    echo "origin left unchanged." >&2
    exit 1
fi
TIB_SHA="$(cut -f1 /tmp/ckg-lsremote.txt)"
rm -f /tmp/ckg-lsremote.txt /tmp/ckg-lsremote.err
echo "[OK] TIB $BRANCH = ${TIB_SHA:0:7}"

# ------------------------------------------------------------------
# Switch: keep the old origin as 'github', point origin at TIB
# ------------------------------------------------------------------
if [ "$OLD_URL" = "$TIB_URL" ]; then
    echo "origin already points at the TIB URL - nothing to switch."
else
    if git remote get-url github >/dev/null 2>&1; then
        git remote set-url github "$OLD_URL"
    else
        git remote add github "$OLD_URL"
    fi
    git remote set-url origin "$TIB_URL"
fi

if ! git fetch origin "$BRANCH"; then
    echo "[error] fetch from new origin failed - restoring previous origin" >&2
    git remote set-url origin "$OLD_URL"
    exit 1
fi

git branch --set-upstream-to="origin/$BRANCH" "$(git rev-parse --abbrev-ref HEAD)" >/dev/null

echo ""
echo "[OK] origin -> TIB git ; old remote kept as 'github'"
git remote -v | sed -E 's#(https?://)[^@/]+@#\1***@#'
echo ""
echo "Local HEAD : $(git rev-parse --short HEAD)"
echo "origin/$BRANCH : $(git rev-parse --short "origin/$BRANCH")"
if git merge-base --is-ancestor HEAD "origin/$BRANCH"; then
    echo "Fast-forward possible. Next: git pull --ff-only"
else
    echo "[warn] Local HEAD is not an ancestor of origin/$BRANCH - do NOT deploy until reconciled."
fi
