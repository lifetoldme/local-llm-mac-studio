# Local LLM Stack — Mac Studio (Apple Silicon)

A fully self-hosted local LLM setup running on an Apple Silicon Mac Studio with 32GB RAM, using three independent `mlx_lm.server` instances for fast, reasoning, and coding workloads.

---

## Architecture

```
macOS (native, Metal GPU accelerated — MLX)
├── mlx_lm.server  (fast/light model)    →  :8080   ← Home Assistant, quick queries
├── mlx_lm.server  (reasoning model)     →  :8081   ← Open WebUI default, log analysis
└── mlx_lm.server  (coding model)        →  :8082   ← JetBrains / opencode agent

Docker via Colima
├── open-webui               →  :3000  (connects to all three endpoints)
├── chromadb                 →  :8000  Vector DB for RAG
└── searxng                  →  internal only (optional: :8081)
```

All three MLX servers expose OpenAI-compatible endpoints such as `/v1/chat/completions` and `/v1/models`.

---

## Hardware Requirements

- Apple Silicon Mac (M1 or later)
- 32GB unified memory recommended
- macOS 26 (Tahoe) or later

---

## Prerequisites

Install Homebrew packages:

```bash
brew install colima docker docker-compose hf pipx
```

Install MLX server tooling via pipx:

```bash
pipx install mlx-lm
pipx ensurepath
source ~/.zshrc
```

> **Why pipx?** macOS 13+ protects the system Python environment from direct `pip install` calls (PEP 668). `pipx` is the recommended solution — it installs Python applications into isolated virtual environments and symlinks the binaries onto your PATH automatically.

After installation, verify the binary path:

```bash
which mlx_lm.server
```

The path will typically be something like `/Users/<you>/.local/bin/mlx_lm.server`. The LaunchAgent plists in this repo default to `/usr/local/bin/mlx_lm.server`. If your path differs, run the following to update all three plists before bootstrapping them:

```bash
MLX_PATH=$(which mlx_lm.server)
sed -i '' "s|/usr/local/bin/mlx_lm.server|$MLX_PATH|g" \
  ~/Library/LaunchAgents/com.mlx.fast.plist \
  ~/Library/LaunchAgents/com.mlx.reasoning.plist \
  ~/Library/LaunchAgents/com.mlx.coding.plist
```

Verify the substitution:

```bash
grep -A3 "ProgramArguments" ~/Library/LaunchAgents/com.mlx.fast.plist
```

The first `<string>` inside `<array>` should show your actual path.

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

Point Docker at Colima's socket (add to `~/.zshrc`):

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

### 2. Download models

All three models can be chained into a single command. Total download is ~20GB:

```bash
sudo mkdir -p /opt/models
sudo chown $(whoami) /opt/models

hf download mlx-community/Qwen2.5-3B-Instruct-4bit \
  --local-dir /opt/models/qwen2.5-3b && \
hf download mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit \
  --local-dir /opt/models/deepseek-r1-14b && \
hf download mlx-community/Qwen2.5-Coder-14B-Instruct-4bit \
  --local-dir /opt/models/qwen2.5-coder-14b
```

### 3. Run the install script

```bash
./scripts/install.sh
```

### 4. Run the SearXNG setup script

```bash
./scripts/setup-searxng.sh
```

### 5. Verify the full stack

```bash
./scripts/status.sh
```

---

## Auto-start (LaunchAgents)

LaunchAgents in `~/Library/LaunchAgents/`:

| Plist | Role | Model | Port | Behavior |
|---|---|---|---|---|
| `com.mlx.fast.plist` | Fast/light | `mlx-community/Qwen2.5-3B-Instruct-4bit` | 8080 | Persistent, restarts on crash |
| `com.mlx.reasoning.plist` | Reasoning | `mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit` | 8081 | Persistent, restarts on crash |
| `com.mlx.coding.plist` | Coding | `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit` | 8082 | Persistent, restarts on crash |
| `com.colima.server.plist` | Docker VM | Colima | n/a | Persistent, restarts on crash |
| `com.localllm.compose.plist` | Containers | Open WebUI/ChromaDB/SearXNG | n/a | One-shot compose up |

Manage LaunchAgents:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/<plist>.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>.plist
launchctl list | grep -E "mlx|colima|localllm"
```

> **macOS 26 note:** Use `launchctl bootstrap` not `launchctl load`. If bootstrap fails with error 5, strip extended attributes:
> ```bash
> xattr -c ~/Library/LaunchAgents/<plist>.plist
> ```

---

## Configuration

### MLX server configuration

| Service | Model | Host | Port |
|---|---|---|---|
| Fast | `mlx-community/Qwen2.5-3B-Instruct-4bit` | `0.0.0.0` | `8080` |
| Reasoning | `mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit` | `0.0.0.0` | `8081` |
| Coding | `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit` | `0.0.0.0` | `8082` |

### Swapping models

1. Edit the relevant plist in `~/Library/LaunchAgents/` and change `--model`.
2. Reload it:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.mlx.<role>.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mlx.<role>.plist
```

3. Confirm with:

```bash
curl http://localhost:<port>/v1/models
```

### Recommended models (32GB RAM)

| Role | Model | Est. RAM | Port |
|---|---|---|---|
| Fast/light | `mlx-community/Qwen2.5-3B-Instruct-4bit` | ~2GB | 8080 |
| Reasoning | `mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit` | ~9GB | 8081 |
| Coding | `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit` | ~9GB | 8082 |

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

---

## Open WebUI Connections

`docker/docker-compose.yml` configures Open WebUI with all three local endpoints using:

- `OPENAI_API_BASE_URLS=http://host.docker.internal:8080/v1;http://host.docker.internal:8081/v1;http://host.docker.internal:8082/v1`
- `OPENAI_API_KEYS=none;none;none`

Open WebUI will discover all three endpoints and expose model selection via the model picker per conversation. You can also manage endpoints in **Admin → Connections**.

---

## Per-app routing guide

| App | Endpoint | Reason |
|---|---|---|
| **Home Assistant** | `http://<HOST_IP>:8080/v1` | Fast, low-latency responses |
| **Open WebUI** | `:8081` default, `:8082` selectable | Reasoning for general chat, coding on demand |
| **opencode / JetBrains** | `http://<HOST_IP>:8082/v1` | Coding-optimised model |
| **Log monitoring/analysis** | `http://<HOST_IP>:8081/v1` | Reasoning model for anomaly detection |

---

## Maintenance

```bash
./scripts/status.sh              # Health check all services
./scripts/update.sh              # Update everything
./scripts/update.sh --mlx        # Update mlx-lm only
./scripts/update.sh --docker     # Update Open WebUI, ChromaDB, SearXNG only
./scripts/update.sh --colima     # Update Colima only
```

---

## Logs

| Service | Location |
|---|---|
| MLX fast stdout | `/var/log/mlx/fast.log` |
| MLX fast stderr | `/var/log/mlx/fast.error.log` |
| MLX reasoning stdout | `/var/log/mlx/reasoning.log` |
| MLX reasoning stderr | `/var/log/mlx/reasoning.error.log` |
| MLX coding stdout | `/var/log/mlx/coding.log` |
| MLX coding stderr | `/var/log/mlx/coding.error.log` |
| Open WebUI | `docker logs open-webui` |
| ChromaDB | `docker logs chromadb` |
| SearXNG | `docker logs searxng` |

---

## Troubleshooting

### `pip install mlx-lm` fails with "externally-managed-environment"

macOS 13+ (and Homebrew Python) block direct `pip install` calls to protect the system environment (PEP 668). Use `pipx` instead:

```bash
brew install pipx
pipx install mlx-lm
pipx ensurepath
source ~/.zshrc
```

### LaunchAgents fail — wrong `mlx_lm.server` path

The plists default to `/usr/local/bin/mlx_lm.server`. If `pipx` installed it elsewhere (commonly `~/.local/bin/`), update all three plists:

```bash
MLX_PATH=$(which mlx_lm.server)
sed -i '' "s|/usr/local/bin/mlx_lm.server|$MLX_PATH|g" \
  ~/Library/LaunchAgents/com.mlx.fast.plist \
  ~/Library/LaunchAgents/com.mlx.reasoning.plist \
  ~/Library/LaunchAgents/com.mlx.coding.plist
```

Verify:

```bash
grep -A3 "ProgramArguments" ~/Library/LaunchAgents/com.mlx.fast.plist
```

Then reload the agents:

```bash
for plist in com.mlx.fast com.mlx.reasoning com.mlx.coding; do
  launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/$plist.plist 2>/dev/null || true
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$plist.plist
done
```

### launchctl bootstrap fails with error 5

Known issue on macOS 26 (Tahoe). Fix:

```bash
xattr -c ~/Library/LaunchAgents/<plist>.plist
sudo chown $(whoami) /var/log/mlx/
```

### Model download issues

```bash
hf auth login
hf download mlx-community/Qwen2.5-3B-Instruct-4bit --local-dir /opt/models/qwen2.5-3b
```

### Port conflicts (8080/8081/8082)

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
lsof -nP -iTCP:8081 -sTCP:LISTEN
lsof -nP -iTCP:8082 -sTCP:LISTEN
```

Stop the conflicting process, then reload the affected LaunchAgent.

### Open WebUI cannot reach MLX servers

```bash
# From host
curl http://localhost:8080/v1/models
curl http://localhost:8081/v1/models
curl http://localhost:8082/v1/models

# From inside Open WebUI container
docker exec open-webui curl http://host.docker.internal:8080/v1/models
docker exec open-webui curl http://host.docker.internal:8081/v1/models
docker exec open-webui curl http://host.docker.internal:8082/v1/models
```

If container checks fail, verify this entry exists in `docker/docker-compose.yml`:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

### SearXNG not returning results in Open WebUI

```bash
docker exec open-webui curl -sf "http://searxng:8080/search?q=test&format=json"
docker logs searxng
grep -A5 "formats:" ~/docker/local-llm/searxng/settings.yml
```

If `settings.yml` is missing or corrupted, re-run `./scripts/setup-searxng.sh`.

### Docker commands fail — socket not found

```bash
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
```

Add permanently to `~/.zshrc` if missing.

### `docker compose` not found

Ensure `~/.docker/config.json` has the `cliPluginsExtraDirs` entry pointing to `/opt/homebrew/lib/docker/cli-plugins`.

---

## Repository Structure

```
local-llm-mac-studio/
├── README.md
├── launchagents/
│   ├── com.mlx.fast.plist
│   ├── com.mlx.reasoning.plist
│   ├── com.mlx.coding.plist
│   ├── com.colima.server.plist
│   └── com.localllm.compose.plist
├── docker/
│   └── docker-compose.yml
├── searxng/
│   └── settings.yml
└── scripts/
    ├── install.sh
    ├── setup-searxng.sh
    ├── update.sh
    └── status.sh
```
