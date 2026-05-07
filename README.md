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
brew install colima docker docker-compose hf
```

Install MLX server tooling via pip:

```bash
python3 -m pip install --user mlx-lm
```

> `mlx_lm.server` path can vary by Python setup. Verify with:
>
> ```bash
> which mlx_lm.server
> python3 -m mlx_lm.server --help
> ```
>
> LaunchAgent plists in this repo default to `/usr/local/bin/mlx_lm.server`. Update if your path differs.

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

```bash
sudo mkdir -p /opt/models
sudo chown $(whoami) /opt/models

hf download mlx-community/Qwen2.5-3B-Instruct-4bit --local-dir /opt/models/qwen2.5-3b
hf download mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit --local-dir /opt/models/deepseek-r1-14b
hf download mlx-community/Qwen2.5-Coder-14B-Instruct-4bit --local-dir /opt/models/qwen2.5-coder-14b
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

---

## Open WebUI Connections

`docker/docker-compose.yml` configures Open WebUI with all three local endpoints using:

- `OPENAI_API_BASE_URLS=http://host.docker.internal:8080/v1;http://host.docker.internal:8081/v1;http://host.docker.internal:8082/v1`
- `OPENAI_API_KEYS=none;none;none`

Open WebUI will discover all three endpoints and expose model selection via the model picker per conversation.
You can also manage endpoints in **Admin → Connections**.

---

## Per-app routing guide

- **Home Assistant** → `http://<HOST_IP>:8080/v1` (fast, low latency)
- **Open WebUI** → default to `:8081`, optionally select coding models from `:8082`
- **opencode / JetBrains** → `http://<HOST_IP>:8082/v1`
- **Log monitoring/analysis** → `http://<HOST_IP>:8081/v1`

---

## Maintenance

```bash
./scripts/status.sh
./scripts/update.sh
./scripts/update.sh --mlx
./scripts/update.sh --docker
./scripts/update.sh --colima
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

### Find the `mlx_lm.server` binary path

```bash
which mlx_lm.server
python3 -m mlx_lm.server --help
```

If needed, update `/usr/local/bin/mlx_lm.server` in each plist and reload with `launchctl`.

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

Stop conflicting process, then reload the affected LaunchAgent.

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

If container checks fail, verify this entry exists in compose:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

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
