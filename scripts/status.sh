#!/bin/bash
# =============================================================
# status.sh
# Check the health of all local LLM stack services
# Usage: ./scripts/status.sh
# =============================================================

export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

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

# Returns 0 if the given command is available on PATH
have() { command -v "$1" >/dev/null 2>&1; }

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
check_agent "com.mlx.indepth"    "MLX indepth LaunchAgent"

# Colima agent: runs periodically via StartInterval; check actual Colima state.
# NOTE: `colima status` writes its "colima is running" line to STDERR, so we must
# redirect 2>&1 (not 2>/dev/null) or the grep below will never match.
# Capture once here and reuse in the Processes section to avoid a duplicate call.
colima_result=$(launchctl list | grep "com.colima.server" 2>/dev/null)
COLIMA_STATUS=$(colima status 2>&1)
colima_running=$(echo "$COLIMA_STATUS" | grep -q "colima is running" && echo "yes" || echo "no")
# Retry once — Colima may be mid-startup
if [ "$colima_running" = "no" ]; then
  sleep 3
  COLIMA_STATUS=$(colima status 2>&1)
  colima_running=$(echo "$COLIMA_STATUS" | grep -q "colima is running" && echo "yes" || echo "no")
fi
if [ "$colima_running" = "yes" ]; then
  if [ -n "$colima_result" ]; then
    colima_pid=$(echo "$colima_result" | awk '{print $1}')
    if [ "$colima_pid" != "-" ]; then
      pass "Colima LaunchAgent — running (PID $colima_pid)"
    else
      pass "Colima LaunchAgent — interval check active (Colima is running)"
    fi
  else
    fail "Colima LaunchAgent — not registered (but Colima is running)"
  fi
else
  if [ -z "$colima_result" ]; then
    fail "Colima LaunchAgent — not registered (Colima is NOT running)"
  else
    colima_exit=$(echo "$colima_result" | awk '{print $2}')
    fail "Colima LaunchAgent — exit $colima_exit (Colima is NOT running)"
  fi
fi

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
  pass "mlx_lm.server indepth (PID $PID)"
else
  fail "mlx_lm.server indepth — not running"
fi

# Reuse the COLIMA_STATUS captured in the LaunchAgents section above
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
  if ! have docker; then
    fail "docker CLI not found on PATH — run: brew link docker"
    info "Skipping container checks"
  else
    check_container "open-webui"
    check_container "chromadb"
    check_container "searxng"
  fi
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
check_endpoint "MLX indepth model API"   "http://localhost:8081/v1/models"        "model"
check_endpoint "ChromaDB"                "http://localhost:8000/api/v2/heartbeat" "heartbeat"
check_endpoint "Open WebUI"              "http://localhost:3000"                  ""

# SearXNG check — must be done from inside the Open WebUI container
# since SearXNG is not exposed on the host network by default
echo -ne "  "
if ! have docker; then
  fail "SearXNG — cannot check (docker CLI not found on PATH)"
elif ! docker inspect open-webui >/dev/null 2>&1; then
  fail "SearXNG — cannot check (open-webui container not found)"
else
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
fi

echo ""

# --------------------------------------------------------------
# Model Integrity (MLX ↔ Open WebUI)
# --------------------------------------------------------------
echo -e "${BOLD}Model Integrity (MLX ↔ Open WebUI)${NC}"

mlx_fast=$(curl -s --max-time 5 http://localhost:8080/v1/models 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)
mlx_indepth=$(curl -s --max-time 5 http://localhost:8081/v1/models 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)

if [ -z "$mlx_fast" ]; then mlx_fast="(not responding)"; fi
if [ -z "$mlx_indepth" ]; then mlx_indepth="(not responding)"; fi

info "MLX fast:      $mlx_fast"
info "MLX indepth:   $mlx_indepth"

# Fetch Open WebUI cached models for comparison
if have docker && docker inspect open-webui >/dev/null 2>&1; then
  OWUI_MODELS=$(docker exec open-webui python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')
cur = conn.cursor()
cur.execute('SELECT id, name FROM model ORDER BY id')
for row in cur.fetchall():
    print(f'{row[0]}={row[1]}')
" 2>/dev/null)

  if [ -z "$OWUI_MODELS" ]; then
    warn "Open WebUI has no models cached"
    info "Run: ./scripts/update.sh --mlx to sync models"
  else
    while IFS='=' read -r model_id model_name; do
      if [ -n "$model_id" ]; then
        info "Open WebUI:    $model_id ($model_name)"
        # Check if this cached model matches any MLX endpoint
        matched=false
        if [ "$model_id" = "$mlx_fast" ]; then
          pass "  ↳ matches MLX fast endpoint"
          matched=true
        fi
        if [ "$model_id" = "$mlx_indepth" ]; then
          pass "  ↳ matches MLX indepth endpoint"
          matched=true
        fi
        if [ "$matched" = false ]; then
          warn "  ↳ not found on any MLX endpoint — cached model may be stale"
        fi
      fi
    done <<< "$OWUI_MODELS"
  fi
else
  warn "Skipping Open WebUI model check — container not available"
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

for ERROR_LOG in /var/log/mlx/fast.error.log /var/log/mlx/indepth.error.log; do
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
info "MLX indepth API:   http://$HOST_IP:8081/v1"
info "ChromaDB:          http://$HOST_IP:8000"
info "SearXNG:           internal only (uncomment ports in docker-compose.yml for browser access at :8081)"

echo ""
echo -e "${BOLD}==============================================${NC}"
echo ""
