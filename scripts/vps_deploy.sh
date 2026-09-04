#!/bin/bash

set -euo pipefail

# ===== COLORS =====
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
CYAN="\033[0;36m"
NC="\033[0m"

log() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

success() {
    echo -e "${GREEN}✅ $1${NC}"
}

warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

error() {
    echo -e "${RED}❌ $1${NC}"
}

# ===== LOAD ENV =====
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# ===== INPUT =====
ENV="$1"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════╗"
echo "║        🚀 CAPROVER DEPLOY            ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}"

# ===== ENV CONFIG =====
case "$ENV" in
    server)
        APP_NAME="granite-server"
        CAPROVER_APP_TOKEN="$CAPROVER_APP_TOKEN_GRANITE_SERVER"
        REQUIRED_BRANCH="trade3"
        ;;
    *)
        error "Invalid environment. Use 'server'."
        exit 1
        ;;
esac

# ===== TOKEN CHECK =====
if [ -z "${CAPROVER_APP_TOKEN:-}" ]; then
    error "Missing CapRover app token."
    exit 1
fi

# ===== BRANCH CHECK =====
if [ "$BRANCH" != "$REQUIRED_BRANCH" ] && [ "$REQUIRED_BRANCH" != "*" ]; then
    error "Deployment refused."
    echo
    echo "Target environment : $ENV"
    echo "Required branch    : $REQUIRED_BRANCH"
    echo "Current branch     : $BRANCH"
    echo
    exit 1
fi

# ===== GIT CHECK =====
if git status --porcelain | grep -q '^.*functions/'; then
    error "Uncommitted changes detected in functions/."
    warn "Commit or stash your changes before deploying."
    exit 1
fi

# ===== BOX =====
strlen() {
    awk '{ print length }' <<<"$1"
}

print_box() {
    local lines=("$@")
    local max=0

    for line in "${lines[@]}"; do
        local len
        len=$(strlen "$line")
        (( len > max )) && max=$len
    done

    local width=$((max + 2))
    local border
    border=$(printf '─%.0s' $(seq 1 "$width"))

    echo "┌${border}┐"

    for line in "${lines[@]}"; do
        local len
        len=$(strlen "$line")
        local spaces=$((width - len))
        printf "│ %s%*s │\n" "$line" "$spaces" ""
    done

    echo "└${border}┘"
}

echo -e "${BLUE}"
print_box \
    "📦 App      : ${APP_NAME}" \
    "🌿 Branch   : ${BRANCH}" \
    "🎯 Target   : ${ENV}" \
    "🌍 Server   : ${CAPROVER_URL}"
echo -e "${NC}"

# ===== CONFIRM =====
if [ "${CI:-false}" != "true" ]; then
    echo -ne "${YELLOW}👉 Confirm deploy? (y/n) ${NC}"
    read -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        warn "Deployment cancelled."
        exit 0
    fi
fi

START_TIME=$(date +%s)

log "Deploying..."

npx caprover deploy \
    --caproverUrl "$CAPROVER_URL" \
    --appName "$APP_NAME" \
    --branch "$BRANCH" \
    --appToken "$CAPROVER_APP_TOKEN"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "${GREEN}"
echo "╔══════════════════════════════════════╗"
echo "║        🎉 DEPLOY SUCCESSFUL          ║"
echo "╚══════════════════════════════════════╝"
echo -e "${NC}"

success "Deployed in ${DURATION}s 🚀"