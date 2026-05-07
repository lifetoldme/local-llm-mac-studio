#!/bin/bash
# =============================================================
# status.sh
# Check the health of all local LLM stack services
# Usage: ./scripts/status.sh
# =============================================================

export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

# Derive paths dynamically — works from any clone location
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR=~/docker/local-llm

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✔${NC}  $1"; }
fail() { echo -e "  ${RED}✘${NC}  $1"; }
warn() { echo -e "  ${YELLOW}!${NC}  $1"; }
info() { echo -e "  ${BLUE}→${NC}  $1"; }

echo ""
echo -e "${BOLD}=============================================="
echo -e "  Local LLM Stack — Status"
echo -e "==============================================${NC}"
echo ""

# --------------------------------------------------------------
# LaunchAgents
# --------------------------------------------------------------
echo -e "${BOLD}LaunchAgents${NC}"

check_agent() {
  local label="$1"
  local display="$2"
  local one_shot="${3:-false}"  # pass "true" for one-shot commands that exit after running
  result=$(launchctl list | grep "$label" 2>/dev/null)
  if [ -z "$result" ]; then
    fail "$display — not registered"
    return
  fi
  pid=$(echo "$result" | awk '{print $1}')
  exit_code=$(echo "$result" | awk '{print $2}')
  if [ "$pid" != "-" ]; then
    pass "$display — running (PID $pid)"
  elif [ "$exit_code" = "0" ] && [ "$one_shot" = "true" ]; then
    pass "$display — completed successfully (exit 0)"
  elif [ "$exit_code" = "0" ]; then
    warn "$display — registered, not running (last exit: 0)"
  else
    fail "$display — crashed (last exit code: $exit_code)"
  fi
}

check_agent "com.mlx.fast"       "MLX fast LaunchAgent"
check_agent "com.mlx.reasoning"  "MLX reasoning LaunchAgent"
check_agent "com.mlx.coding"     "MLX coding LaunchAgent"
check_agent "com.colima.server"  "Colima LaunchAgent"
check_agent "com.localllm.compose" "Docker Compose LaunchAgent"  "true"

info "launchctl list | grep mlx"
launchctl list | grep "mlx" 2>/dev/null || warn "No mlx LaunchAgents listed"

echo ""

# --------------------------------------------------------------
# Processes
# --------------------------------------------------------------
echo -e "${BOLD}Processes${NC}"

if pgrep -f "mlx_lm.server.*--port 8080" >/dev/null; then
  PID=$(pgrep -f "mlx_lm.server.*--port 8080" | tr '\n' ' ')
  pass "mlx_lm.server fast (PID $PID)"
else
  fail "mlx_lm.server fast — not running"
fi

if pgrep -f "mlx_lm.server.*--port 8081" >/dev/null; then
  PID=$(pgrep -f "mlx_lm.server.*--port 8081" | tr '\n' ' ')
  pass "mlx_lm.server reasoning (PID $PID)"
else
  fail "mlx_lm.server reasoning — not running"
fi

if pgrep -f "mlx_lm.server.*--port 8082" >/dev/null; then
  PID=$(pgrep -f "mlx_lm.server.*--port 8082" | tr '\n' ' ')
  pass "mlx_lm.server coding (PID $PID)"
else
  fail "mlx_lm.server coding — not running"
fi

COLIMA_STATUS=$(colima status 2>&1)
if echo "$COLIMA_STATUS" | grep -q "colima is running"; then
  pass "Colima VM"
  info "$(echo "$COLIMA_STATUS" | grep 'arch:' | sed 's/.*msg=//' | tr -d '"')"
  info "$(echo "$COLIMA_STATUS" | grep 'runtime:' | sed 's/.*msg=//' | tr -d '"')"
else
  fail "Colima VM — not running"
fi

echo ""

# --------------------------------------------------------------
# Docker containers
# --------------------------------------------------------------
echo -e "${BOLD}Docker Containers${NC}"

check_container() {
  local name="$1"
  local status
  status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null)
  health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)

  if [ -z "$status" ]; then
    fail "$name — not found"
  elif [ "$status" = "running" ] && [ "$health" = "healthy" ]; then
    pass "$name — running (healthy)"
  elif [ "$status" = "running" ] && [ "$health" = "none" ]; then
    pass "$name — running (no healthcheck)"
  elif [ "$status" = "running" ]; then
    warn "$name — running (health: $health)"
  else
    fail "$name — $status"
  fi
}

if echo "$COLIMA_STATUS" | grep -q "colima is running"; then
  check_container "open-webui"
  check_container "chromadb"
  check_container "searxng"
else
  warn "Skipping container checks — Colima is not running"
fi

echo ""

# --------------------------------------------------------------
# API endpoints
# --------------------------------------------------------------
echo -e "${BOLD}API Endpoints${NC}"

check_endpoint() {
  local name="$1"
  local url="$2"
  local expected="$3"

  response=$(curl -sf --max-time 5 "$url" 2>/dev/null)
  if [ $? -ne 0 ]; then
    fail "$name — not responding ($url)"
    return
  fi
  if [ -n "$expected" ] && ! echo "$response" | grep -q "$expected"; then
    warn "$name — responding but unexpected output ($url)"
    return
  fi
  pass "$name — responding ($url)"
}

check_endpoint "MLX fast model API"      "http://localhost:8080/v1/models"        "model"
check_endpoint "MLX reasoning model API" "http://localhost:8081/v1/models"        "model"
check_endpoint "MLX coding model API"    "http://localhost:8082/v1/models"        "model"
check_endpoint "ChromaDB"                "http://localhost:8000/api/v2/heartbeat" "heartbeat"
check_endpoint "Open WebUI"              "http://localhost:3000"                  ""

# SearXNG check — must be done from inside the Open WebUI container
# since SearXNG is not exposed on the host network by default
echo -ne "  "
SEARXNG_RESULT=$(docker exec open-webui \
  curl -sf --max-time 5 "http://searxng:8080/search?q=test&format=json" 2>/dev/null || echo "")

if echo "$SEARXNG_RESULT" | grep -qE '"results"|"query"'; then
  pass "SearXNG — responding (JSON search working)"
elif [ -z "$SEARXNG_RESULT" ]; then
  fail "SearXNG — not responding from Open WebUI container"
else
  warn "SearXNG — responding but JSON format may not be enabled"
  info "Check: grep -A5 'formats:' ~/docker/local-llm/searxng/settings.yml"
fi

echo ""

# --------------------------------------------------------------
# SearXNG configuration details
# --------------------------------------------------------------
echo -e "${BOLD}SearXNG Configuration${NC}"

SETTINGS_FILE="$COMPOSE_DIR/searxng/settings.yml"
if [ -f "$SETTINGS_FILE" ]; then
  if grep -qF -- "- json" "$SETTINGS_FILE"; then
    pass "JSON format enabled in settings.yml"
  else
    fail "JSON format NOT enabled in settings.yml — Open WebUI web search will not work"
    info "Fix: add '- json' under 'formats:' in $SETTINGS_FILE"
    info "Then run: docker compose restart searxng"
  fi
else
  warn "settings.yml not found at $SETTINGS_FILE"
  info "Run ./scripts/setup-searxng.sh to initialize SearXNG"
fi

echo ""

# --------------------------------------------------------------
# Recent errors
# --------------------------------------------------------------
echo -e "${BOLD}Recent Errors (last 5 lines per mlx error log)${NC}"

for ERROR_LOG in /var/log/mlx/fast.error.log /var/log/mlx/reasoning.error.log /var/log/mlx/coding.error.log; do
  if [ -f "$ERROR_LOG" ]; then
    errors=$(tail -n 20 "$ERROR_LOG" | grep -i "error\|failed\|fatal" | tail -n 5)
    if [ -n "$errors" ]; then
      warn "$(basename "$ERROR_LOG")"
      echo "$errors" | while IFS= read -r line; do
        warn "$line"
      done
    else
      pass "No recent errors in $(basename "$ERROR_LOG")"
    fi
  else
    warn "Log file not found: $ERROR_LOG"
  fi
done

echo ""

# --------------------------------------------------------------
# Network summary
# --------------------------------------------------------------
HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "unknown")
echo -e "${BOLD}Network${NC}"
info "Host IP:           $HOST_IP"
info "Open WebUI:        http://$HOST_IP:3000"
info "MLX fast API:      http://$HOST_IP:8080/v1"
info "MLX reasoning API: http://$HOST_IP:8081/v1"
info "MLX coding API:    http://$HOST_IP:8082/v1"
info "ChromaDB:          http://$HOST_IP:8000"
info "SearXNG:           internal only (uncomment ports in docker-compose.yml for browser access at :8081)"

echo ""
echo -e "${BOLD}==============================================${NC}"
echo ""
