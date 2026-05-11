#!/bin/bash
# =============================================================
# install.sh
# One-shot setup script for the local LLM stack on Apple Silicon
# Usage: ./scripts/install.sh
# =============================================================

set -e  # Exit immediately on any error

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR=~/docker/local-llm

log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "=============================================="
echo "  Local LLM Stack — Install"
echo "=============================================="
echo ""

# --------------------------------------------------------------
# 1. Check prerequisites
# --------------------------------------------------------------
log_info "Checking prerequisites..."

command -v brew >/dev/null 2>&1 || log_error "Homebrew is not installed. Install it first: https://brew.sh"

for pkg in colima docker docker-compose hf pipx; do
  if ! brew list "$pkg" &>/dev/null; then
    log_info "Installing $pkg via Homebrew..."
    brew install "$pkg"
  else
    log_success "$pkg already installed"
  fi
done

log_info "Installing mlx-lm via pipx..."
# pipx manages its own isolated venv — avoids PEP 668 externally-managed-environment errors
if pipx list | grep -q "mlx-lm"; then
  pipx upgrade mlx-lm
  log_success "mlx-lm upgraded"
else
  pipx install mlx-lm
  pipx ensurepath
  log_success "mlx-lm installed"
fi

# Verify binary is on PATH
if ! command -v mlx_lm.server >/dev/null 2>&1; then
  log_warn "mlx_lm.server not found on PATH. You may need to run: pipx ensurepath && source ~/.zshrc"
  log_warn "Then re-run this script, or manually update the LaunchAgent plists with the correct path."
else
  log_success "mlx_lm.server found at: $(which mlx_lm.server)"
fi

# Update LaunchAgent plists if the binary path differs from the default
MLX_PATH="$(which mlx_lm.server 2>/dev/null || true)"
DEFAULT_PATH="/usr/local/bin/mlx_lm.server"

if [ -n "$MLX_PATH" ] && [ "$MLX_PATH" != "$DEFAULT_PATH" ]; then
  log_info "Updating LaunchAgent plists with mlx_lm.server path: $MLX_PATH"
  for plist in com.mlx.fast.plist com.mlx.reasoning.plist com.mlx.coding.plist; do
    sed -i '' "s|$DEFAULT_PATH|$MLX_PATH|g" "$REPO_DIR/launchagents/$plist"
  done
  log_success "Plist paths updated"
fi

# --------------------------------------------------------------
# 2. Create required directories
# --------------------------------------------------------------
log_info "Creating required directories..."

sudo mkdir -p /var/log/mlx
sudo chown "$(whoami)" /var/log/mlx
log_success "/var/log/mlx created"

mkdir -p ~/Library/LaunchAgents
log_success "~/Library/LaunchAgents exists"

mkdir -p "$COMPOSE_DIR"
log_success "$COMPOSE_DIR created"

# --------------------------------------------------------------
# 3. Configure Docker plugin path
# --------------------------------------------------------------
log_info "Configuring Docker CLI plugin path..."

mkdir -p ~/.docker
DOCKER_CONFIG=~/.docker/config.json

if [ ! -f "$DOCKER_CONFIG" ]; then
  cat > "$DOCKER_CONFIG" << 'JSONEOF'
{
  "cliPluginsExtraDirs": [
    "/opt/homebrew/lib/docker/cli-plugins"
  ]
}
JSONEOF
  log_success "Created ~/.docker/config.json"
else
  # Check if the plugin dir is already present
  if ! grep -q "cliPluginsExtraDirs" "$DOCKER_CONFIG"; then
    log_warn "~/.docker/config.json exists but is missing cliPluginsExtraDirs. Add it manually:"
    echo '  "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]'
  else
    log_success "~/.docker/config.json already configured"
  fi
fi

# --------------------------------------------------------------
# 4. Configure DOCKER_HOST in shell profile
# --------------------------------------------------------------
log_info "Configuring DOCKER_HOST in ~/.zshrc..."

DOCKER_HOST_LINE='export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"'
if ! grep -qF "$DOCKER_HOST_LINE" ~/.zshrc 2>/dev/null; then
  echo "" >> ~/.zshrc
  echo "# Added by local-llm install.sh" >> ~/.zshrc
  echo "$DOCKER_HOST_LINE" >> ~/.zshrc
  log_success "DOCKER_HOST added to ~/.zshrc"
else
  log_success "DOCKER_HOST already set in ~/.zshrc"
fi

export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

# --------------------------------------------------------------
# 5. Install LaunchAgents
# --------------------------------------------------------------
log_info "Installing LaunchAgents..."

PLISTS=(
  "com.mlx.fast.plist"
  "com.mlx.reasoning.plist"
  "com.mlx.coding.plist"
  "com.colima.server.plist"
  "com.localllm.compose.plist"
)

for plist in "${PLISTS[@]}"; do
  SRC="$REPO_DIR/launchagents/$plist"
  DEST="$HOME/Library/LaunchAgents/$plist"

  if [ ! -f "$SRC" ]; then
    log_error "Plist not found: $SRC"
  fi

  cp "$SRC" "$DEST"
  xattr -c "$DEST"  # Strip quarantine and any other extended attributes

  # Unload first in case it's already registered (ignore errors)
  launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true

  launchctl bootstrap "gui/$(id -u)" "$DEST"
  log_success "Loaded $plist"
done

# --------------------------------------------------------------
# 6. Copy Docker Compose file
# --------------------------------------------------------------
log_info "Copying docker-compose.yml..."

cp "$REPO_DIR/docker/docker-compose.yml" ~/docker/local-llm/docker-compose.yml
log_success "docker-compose.yml copied to ~/docker/local-llm/"

# --------------------------------------------------------------
# 7. Start Colima
# --------------------------------------------------------------
log_info "Starting Colima..."

if colima status 2>/dev/null | grep -q "colima is running"; then
  log_success "Colima is already running"
else
  colima start --cpu 4 --memory 8 --disk 60
  log_success "Colima started"
fi

# --------------------------------------------------------------
# 8. Start Docker Compose stack
# --------------------------------------------------------------
log_info "Starting Docker Compose stack..."

cd ~/docker/local-llm
docker compose up -d
log_success "Open WebUI and ChromaDB started"

# --------------------------------------------------------------
# 9. Final health check
# --------------------------------------------------------------
echo ""
log_info "Waiting 15 seconds for services to initialize..."
sleep 15

echo ""
echo "=============================================="
echo "  Health Check"
echo "=============================================="

# Colima
if colima status 2>/dev/null | grep -q "colima is running"; then
  log_success "Colima is running"
else
  log_warn "Colima is NOT running"
fi

# MLX APIs
if curl -sf http://localhost:8080/v1/models >/dev/null; then
  log_success "MLX fast model API responding on :8080"
else
  log_warn "MLX fast model API not responding — model may still be loading"
fi

if curl -sf http://localhost:8081/v1/models >/dev/null; then
  log_success "MLX reasoning model API responding on :8081"
else
  log_warn "MLX reasoning model API not responding — model may still be loading"
fi

if curl -sf http://localhost:8082/v1/models >/dev/null; then
  log_success "MLX coding model API responding on :8082"
else
  log_warn "MLX coding model API not responding — model may still be loading"
fi

# ChromaDB
if curl -sf http://localhost:8000/api/v2/heartbeat >/dev/null; then
  log_success "ChromaDB responding on :8000"
else
  log_warn "ChromaDB not responding"
fi

# Open WebUI
if curl -sf -o /dev/null http://localhost:3000; then
  log_success "Open WebUI responding on :3000"
else
  log_warn "Open WebUI not responding — may still be starting"
fi

echo ""
echo "=============================================="
echo "  Install complete!"
echo ""
echo "  Open WebUI:         http://$(ipconfig getifaddr en0):3000"
echo "  MLX fast API:       http://$(ipconfig getifaddr en0):8080/v1"
echo "  MLX reasoning API:  http://$(ipconfig getifaddr en0):8081/v1"
echo "  MLX coding API:     http://$(ipconfig getifaddr en0):8082/v1"
echo "  ChromaDB:           http://$(ipconfig getifaddr en0):8000"
echo ""
echo "  Remember to enable auto-login for headless boot:"
echo "  System Settings → General → Login Items & Extensions"
echo "=============================================="
echo ""
