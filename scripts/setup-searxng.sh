#!/bin/bash
# =============================================================
# setup-searxng.sh
# First-run initialization for SearXNG.
# Run this once after cloning the repo on a new machine.
# Usage: ./scripts/setup-searxng.sh
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

# Derive paths dynamically — works from any clone location
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR=~/docker/local-llm
SEARXNG_CONFIG_DIR="$COMPOSE_DIR/searxng"

echo ""
echo "=============================================="
echo "  SearXNG Setup — First Run"
echo "=============================================="
echo ""

# --------------------------------------------------------------
# 1. Verify docker-compose.yml is in the runtime directory
# --------------------------------------------------------------
if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  log_info "Copying docker-compose.yml to $COMPOSE_DIR..."
  mkdir -p "$COMPOSE_DIR"
  cp "$REPO_DIR/docker/docker-compose.yml" "$COMPOSE_DIR/docker-compose.yml"
  log_success "docker-compose.yml copied"
else
  log_success "docker-compose.yml found at $COMPOSE_DIR"
fi

# --------------------------------------------------------------
# 2. Create SearXNG config directory and copy settings
# --------------------------------------------------------------
log_info "Creating SearXNG config directory..."
mkdir -p "$SEARXNG_CONFIG_DIR"

if [ ! -f "$SEARXNG_CONFIG_DIR/settings.yml" ]; then
  cp "$REPO_DIR/searxng/settings.yml" "$SEARXNG_CONFIG_DIR/settings.yml"
  log_success "settings.yml copied to $SEARXNG_CONFIG_DIR"
else
  log_warn "settings.yml already exists at $SEARXNG_CONFIG_DIR — skipping copy"
fi

# --------------------------------------------------------------
# 3. Generate a random secret key and inject it into settings.yml
# --------------------------------------------------------------
log_info "Generating SearXNG secret key..."
if grep -q 'secret_key: "changeme"' "$SEARXNG_CONFIG_DIR/settings.yml"; then
  SECRET_KEY=$(openssl rand -hex 32)
  sed -i '' "s/secret_key: \"changeme\"/secret_key: \"$SECRET_KEY\"/" \
    "$SEARXNG_CONFIG_DIR/settings.yml"
  log_success "Secret key injected into settings.yml"
else
  log_warn "Secret key already set — skipping"
fi

# --------------------------------------------------------------
# 4. Verify JSON format is enabled in settings.yml
# --------------------------------------------------------------
log_info "Verifying JSON format is enabled in settings.yml..."
if grep -qF -- "- json" "$SEARXNG_CONFIG_DIR/settings.yml"; then
  log_success "JSON format already enabled"
else
  printf '\n    - json' >> "$SEARXNG_CONFIG_DIR/settings.yml"
  log_success "JSON format added to settings.yml"
fi

# --------------------------------------------------------------
# 5. Bring up the full stack
# --------------------------------------------------------------
log_info "Starting Docker Compose stack..."
cd "$COMPOSE_DIR"
docker compose up -d
log_info "Waiting 20 seconds for all services to initialize..."
sleep 20

# --------------------------------------------------------------
# 6. Health checks
# --------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Health Check"
echo "=============================================="

# SearXNG JSON search test — run from inside Open WebUI container
# since SearXNG is not exposed on the host network
SEARXNG_RESULT=$(docker exec open-webui \
  curl -sf --max-time 10 "http://searxng:8080/search?q=test&format=json" 2>/dev/null || echo "")

if echo "$SEARXNG_RESULT" | grep -qE '"results"|"query"'; then
  log_success "SearXNG responding to JSON queries from Open WebUI"
else
  log_warn "SearXNG JSON endpoint not responding as expected"
  log_warn "Check logs: docker logs searxng"
fi

if curl -sf -o /dev/null http://localhost:3000; then
  log_success "Open WebUI responding on :3000"
else
  log_warn "Open WebUI not responding"
fi

if curl -sf http://localhost:8000/api/v2/heartbeat >/dev/null; then
  log_success "ChromaDB responding on :8000"
else
  log_warn "ChromaDB not responding"
fi

echo ""
echo "=============================================="
echo "  SearXNG setup complete!"
echo ""
echo "  Web search is now enabled in Open WebUI."
echo "  In any chat, click the 🌐 icon to toggle"
echo "  web search on or off per conversation."
echo ""
echo "  To expose SearXNG in your browser directly,"
echo "  uncomment the ports section in docker-compose.yml"
echo "  and run: docker compose up -d"
echo "  Then access at: http://$(ipconfig getifaddr en0 2>/dev/null || echo "<HOST_IP>"):8081"
echo "=============================================="
echo ""
