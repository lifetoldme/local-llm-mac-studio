#!/bin/bash
# =============================================================
# update.sh
# Update all components of the local LLM stack
# Usage: ./scripts/update.sh [--all | --mlx | --docker | --colima]
# With no arguments, updates everything.
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

UPDATE_MLX=false
UPDATE_DOCKER=false
UPDATE_COLIMA=false

# Parse arguments — default to all if none provided
if [ $# -eq 0 ]; then
  UPDATE_MLX=true
  UPDATE_DOCKER=true
  UPDATE_COLIMA=true
else
  for arg in "$@"; do
    case $arg in
      --all)    UPDATE_MLX=true; UPDATE_DOCKER=true; UPDATE_COLIMA=true ;;
      --mlx)    UPDATE_MLX=true ;;
      --docker) UPDATE_DOCKER=true ;;
      --colima) UPDATE_COLIMA=true ;;
      *) log_error "Unknown argument: $arg. Use --all, --mlx, --docker, or --colima" ;;
    esac
  done
fi

echo ""
echo "=============================================="
echo "  Local LLM Stack — Update"
echo "=============================================="
echo ""

# --------------------------------------------------------------
# Update mlx-lm
# --------------------------------------------------------------
if [ "$UPDATE_MLX" = true ]; then
  echo "--- mlx-lm ---"
  log_info "Upgrading mlx-lm..."

  python3 -m pip install --user --upgrade mlx-lm

  log_info "Reloading MLX LaunchAgents..."
  for plist in com.mlx.fast.plist com.mlx.reasoning.plist com.mlx.coding.plist; do
    launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/$plist" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$plist"
    log_success "$plist reloaded"
  done
  echo ""
fi

# --------------------------------------------------------------
# Update Docker images (Open WebUI + ChromaDB)
# --------------------------------------------------------------
if [ "$UPDATE_DOCKER" = true ]; then
  echo "--- Docker Compose stack ---"
  log_info "Pulling latest images..."

  cd "$COMPOSE_DIR"
  docker compose pull
  docker compose up -d
  log_success "Open WebUI and ChromaDB updated and restarted"
  echo ""
fi

# --------------------------------------------------------------
# Update Colima
# --------------------------------------------------------------
if [ "$UPDATE_COLIMA" = true ]; then
  echo "--- Colima ---"
  log_info "Checking for Colima updates..."

  BEFORE=$(brew info colima | grep "colima " | awk '{print $2}')
  brew upgrade colima 2>/dev/null || log_warn "Colima already at latest version"
  AFTER=$(brew info colima | grep "colima " | awk '{print $2}')

  if [ "$BEFORE" != "$AFTER" ]; then
    log_info "Updated Colima $BEFORE → $AFTER, restarting..."
    launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.colima.server.plist 2>/dev/null || true
    colima stop 2>/dev/null || true
    sleep 3
    colima start --cpu 4 --memory 8 --disk 60
    launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.colima.server.plist
    log_success "Colima restarted"
  else
    log_success "Colima already at latest version ($AFTER)"
  fi
  echo ""
fi

# --------------------------------------------------------------
# Post-update health check
# --------------------------------------------------------------
echo "=============================================="
echo "  Post-update Health Check"
echo "=============================================="

log_info "Waiting 10 seconds for services to settle..."
sleep 10

if colima status 2>/dev/null | grep -q "colima is running"; then
  log_success "Colima running"
else
  log_warn "Colima NOT running"
fi

if curl -sf http://localhost:8080/v1/models >/dev/null; then
  log_success "MLX fast model API responding"
else
  log_warn "MLX fast model API not responding"
fi

if curl -sf http://localhost:8081/v1/models >/dev/null; then
  log_success "MLX reasoning model API responding"
else
  log_warn "MLX reasoning model API not responding"
fi

if curl -sf http://localhost:8082/v1/models >/dev/null; then
  log_success "MLX coding model API responding"
else
  log_warn "MLX coding model API not responding"
fi

if curl -sf http://localhost:8000/api/v2/heartbeat >/dev/null; then
  log_success "ChromaDB responding"
else
  log_warn "ChromaDB not responding"
fi

if curl -sf -o /dev/null http://localhost:3000; then
  log_success "Open WebUI responding"
else
  log_warn "Open WebUI not responding"
fi

echo ""
echo "=============================================="
echo "  Update complete!"
echo "=============================================="
echo ""
