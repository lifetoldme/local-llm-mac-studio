# Local LLM Stack — Mac Studio (Apple Silicon)

A fully self-hosted local LLM setup running on an Apple Silicon Mac Studio with 32GB RAM. Provides a ChatGPT-style web interface, private web search, and a vector database for RAG — all running locally with no cloud dependencies.

---

## Architecture

```
macOS (native, Metal GPU accelerated)
└── llama-server (llama.cpp)  →  :8080  OpenAI-compatible API

Docker via Colima
├── open-webui               →  :3000  Chat interface
├── chromadb                 →  :8000  Vector DB for RAG
└── searxng                  →  internal only (optional: :8081)
```

The llama.cpp server runs natively on macOS to take full advantage of Apple Silicon's Metal GPU acceleration. All other services run in Docker via Colima.

---

## Hardware Requirements

- Apple Silicon Mac (M1 or later)
- 32GB unified memory minimum
- macOS 26 (Tahoe) or later

---

## Prerequisites

Install the following via Homebrew:

```bash
brew install llama.cpp colima docker docker-compose hf
```

> **Note:** `huggingface-cli` is deprecated. Use `hf` for all model downloads.

Configure Docker to find the Compose plugin:

```bash
mkdir -p ~/.docker
cat > ~/.docker/config.json << 'EOF'
{
  "cliPluginsExtraDirs": [
    "/opt/homebrew/lib/docker/cli-plugins"
  ]
}
EOF
```

Point Docker at Colima's socket — add this to your `~/.zshrc`:

```bash
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
source ~/.zshrc
```

---

## Deployment

### 1. Clone the repo

```bash
mkdir -p ~/Developer
cd ~/Developer
git clone https://github.com/<you>/local-llm-mac-studio.git
cd local-llm-mac-studio
chmod +x scripts/*.sh
```

### 2. Download the model

```bash
sudo mkdir -p /opt/models
sudo chown $(whoami) /opt/models

hf download bartowski/Meta-Llama-3.1-8B-Instruct-GGUF \
  --include "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf" \
  --local-dir /opt/models
```

### 3. Run the install script

```bash
./scripts/install.sh
```

This handles everything in one shot: creates directories, configures Docker, installs and bootstraps all three LaunchAgents, starts Colima, and brings up the Docker Compose stack.

### 4. Run the SearXNG setup script

```bash
./scripts/setup-searxng.sh
```

This copies the SearXNG config, generates a secret key, and verifies the stack is healthy. Only needed once per machine.

### 5. Enable auto-login

For a headless server, enable automatic login so LaunchAgents fire on boot without requiring a manual login:

System Settings → General → Login Items & Extensions → enable automatic login for your user.

### 6. Verify the full stack

```bash
./scripts/status.sh
```

All services should show green. You can also access Open WebUI at `http://<HOST_IP>:3000` from any device on your network.

---

## Auto-start

Three LaunchAgents in `~/Library/LaunchAgents/` handle automatic startup at login:

| Plist | Service | Behavior |
|---|---|---|
| `com.llamacpp.server.plist` | llama-server (Metal GPU) | Persistent, restarts on crash |
| `com.colima.server.plist` | Colima Docker VM | Persistent, restarts on crash |
| `com.localllm.compose.plist` | Open WebUI + ChromaDB + SearXNG | One-shot, runs `docker compose up -d` 30s after login |

### Managing LaunchAgents

```bash
# Reload after editing a plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<plist>.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>.plist

# Check status of all agents
launchctl list | grep -E "llamacpp|colima|localllm"
```

> **macOS 26 note:** Use `launchctl bootstrap` not `launchctl load`. If bootstrap fails with error 5, strip extended attributes: `xattr -c ~/Library/LaunchAgents/<plist>.plist`

---

## Configuration

### llama-server (com.llamacpp.server.plist)

| Flag | Value | Notes |
|---|---|---|
| `--model` | `/opt/models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf` | Path to GGUF model file |
| `--host` | `0.0.0.0` | Listen on all interfaces |
| `--port` | `8080` | API port |
| `--n-gpu-layers` | `99` | Offload all layers to Metal GPU |
| `--ctx-size` | `32768` | Total context split across parallel slots |
| `--parallel` | `2` | Concurrent slots — each gets 16384 tokens |

### Swapping models

```bash
# Download new model
hf download <repo> --include "<model>.gguf" --local-dir /opt/models

# Update the plist
nano ~/Library/LaunchAgents/com.llamacpp.server.plist

# Reload
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.llamacpp.server.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.llamacpp.server.plist
```

### Recommended models for 32GB RAM

| Model | Size | Best for |
|---|---|---|
| Llama 3.1 8B Q4_K_M | ~5GB | General purpose, fast responses |
| Qwen 2.5 Coder 32B Q4_K_M | ~20GB | Coding tasks |
| DeepSeek R1 14B Q4_K_M | ~9GB | Reasoning and analysis |

### Colima resources

Colima is configured with 4 CPUs, 8GB RAM, and 60GB disk. To adjust:

```bash
colima stop
colima start --cpu 4 --memory 8 --disk 60
```

### SearXNG

Config lives at `~/docker/local-llm/searxng/settings.yml`. To add or remove search engines, edit the `engines` list and restart:

```bash
docker compose -f ~/docker/local-llm/docker-compose.yml restart searxng
```

To expose SearXNG in your browser, uncomment the `ports` section in `docker/docker-compose.yml`, redeploy, and access it at `http://<HOST_IP>:8081`.

---

## Maintenance

### Check status

```bash
./scripts/status.sh
```

### Update everything

```bash
./scripts/update.sh
```

Or update individual components:

```bash
./scripts/update.sh --llama    # llama.cpp only
./scripts/update.sh --docker   # Open WebUI, ChromaDB, SearXNG only
./scripts/update.sh --colima   # Colima only
```

---

## Logs

| Service | Location |
|---|---|
| llama-server stdout | `/var/log/llamacpp/server.log` |
| llama-server stderr | `/var/log/llamacpp/server.error.log` |
| Colima | `/var/log/llamacpp/colima.log` |
| Docker Compose autostart | `/var/log/llamacpp/compose.log` |
| Open WebUI | `docker logs open-webui` |
| ChromaDB | `docker logs chromadb` |
| SearXNG | `docker logs searxng` |

---

## Troubleshooting

### launchctl bootstrap fails with error 5

Known issue on macOS 26 (Tahoe). Fix:

```bash
# Strip extended attributes
xattr -c ~/Library/LaunchAgents/<plist>.plist

# Fix log directory ownership if needed
sudo chown $(whoami) /var/log/llamacpp/
```

### llama-server crashes on startup

```bash
cat /var/log/llamacpp/server.error.log
```

Common causes: model file not found, insufficient RAM for `--ctx-size`, binary path changed after Homebrew update (`which llama-server`).

### "Request exceeds available context size"

Increase `--ctx-size` in the plist. With `--parallel 2`, each slot gets `--ctx-size ÷ 2` tokens. Reload after editing.

### Docker commands fail — socket not found

```bash
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
```

Add permanently to `~/.zshrc` if missing.

### `docker compose` not found

Ensure `~/.docker/config.json` has the `cliPluginsExtraDirs` entry pointing to `/opt/homebrew/lib/docker/cli-plugins`.

### SearXNG not returning results in Open WebUI

```bash
# Test from inside the Open WebUI container
docker exec open-webui curl -sf "http://searxng:8080/search?q=test&format=json"

# Check SearXNG logs
docker logs searxng

# Verify JSON format is enabled
grep -A5 "formats:" ~/docker/local-llm/searxng/settings.yml
```

If `settings.yml` is missing or corrupted, re-run `./scripts/setup-searxng.sh`.

### Open WebUI cannot reach llama-server

```bash
# From the host
curl http://localhost:8080/v1/models

# From inside the container
docker exec open-webui curl http://host.docker.internal:8080/v1/models
```

If the container test fails, verify `extra_hosts: host.docker.internal:host-gateway` is present in `docker/docker-compose.yml`.

---

## Repository Structure

```
local-llm-mac-studio/
├── README.md
├── .gitignore
├── launchagents/
│   ├── com.llamacpp.server.plist      # llama-server auto-start
│   ├── com.colima.server.plist        # Colima auto-start
│   └── com.localllm.compose.plist    # Docker Compose auto-start
├── docker/
│   └── docker-compose.yml             # Open WebUI + ChromaDB + SearXNG
├── searxng/
│   └── settings.yml                   # SearXNG config (uwsgi.ini is gitignored)
└── scripts/
    ├── install.sh                     # One-shot setup for a new machine
    ├── setup-searxng.sh               # SearXNG first-run initialization
    ├── update.sh                      # Update all components
    └── status.sh                      # Health check for all services
```