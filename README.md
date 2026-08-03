# Local LLM Stack — Mac Studio (Apple Silicon)

A fully self-hosted local LLM setup running on an Apple Silicon Mac Studio with 32GB RAM, using two independent `mlx_lm.server` instances for fast and in-depth workloads.

---

## Architecture

```
macOS (native, Metal GPU accelerated — MLX)
├── mlx_lm.server  (fast model)       →  :8080   ← Home Assistant, Open WebUI quick chat
└── mlx_lm.server  (indepth model)    →  :8081   ← Open WebUI in-depth (local), Hermes Agent (remote, same LAN)

Docker via Colima
├── open-webui               →  :3000  (connects to both endpoints)
├── chromadb                 →  :8000  Vector DB for RAG
└── searxng                  →  internal only (optional: :8081)
```

All two MLX servers expose OpenAI-compatible endpoints such as `/v1/chat/completions` and `/v1/models`.

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

The path will typically be something like `/Users/<you>/.local/bin/mlx_lm.server`. The LaunchAgent plists in this repo default to `/usr/local/bin/mlx_lm.server`. If your path differs, run the following to update both plists before bootstrapping them:

```bash
MLX_PATH=$(which mlx_lm.server)
sed -i '' "s|/usr/local/bin/mlx_lm.server|$MLX_PATH|g" \
  ~/Library/LaunchAgents/com.mlx.fast.plist \
  ~/Library/LaunchAgents/com.mlx.indepth.plist
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

All two models can be chained into a single command. Total download is ~19GB:

```bash
sudo mkdir -p /opt/models
sudo chown $(whoami) /opt/models

hf download mlx-community/Qwen3-1.7B-4bit \
  --local-dir /opt/models/qwen3-1.7b && \
hf download mlx-community/Qwen3.6-27B-OptiQ-4bit \
  --local-dir /opt/models/qwen3.6-27b-optiq
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

| Plist | Role | Model (`--model`) | Port | Max Tokens | Thinking | Behavior |
|---|---|---|---|---|---|---|
| `com.mlx.fast.plist` | Fast | `/opt/models/qwen3-1.7b` | 8080 | 2048 | Off (`enable_thinking=false`) | Persistent, restarts on crash |
| `com.mlx.indepth.plist` | In-Depth | `/opt/models/qwen3.6-27b-optiq` | 8081 | 16384 | Off (`enable_thinking=false`) | Persistent, restarts on crash |
| `com.colima.server.plist` | Docker VM | Colima | n/a | n/a | n/a | Interval check every 5 min |
| `com.localllm.compose.plist` | Containers | Open WebUI/ChromaDB/SearXNG | n/a | n/a | n/a | One-shot compose up |

> **Local paths, not repo IDs:** the plists load models from `/opt/models/<name>` (the directories created in [step 2](#2-download-models)). `mlx_lm.server` reports this path as the model ID on `/v1/models`, and API clients (Open WebUI, Hermes) must send the same path in the `model` field — see [Model ID is a local path](#model-id-is-a-local-path) in Troubleshooting.

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

| Service | Model (`--model`) | Host | Port | Max Tokens | Thinking |
|---|---|---|---|---|---|
| Fast | `/opt/models/qwen3-1.7b` | `0.0.0.0` | `8080` | 2048 | Off (`enable_thinking=false`) |
| In-Depth | `/opt/models/qwen3.6-27b-optiq` | `0.0.0.0` | `8081` | 16384 | Off (`enable_thinking=false`) |

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

> **Reasoning models & `--max-tokens`:** Reasoning models (Qwen3, DeepSeek-R1, etc.) emit a `…` block *before* the answer. Without `--max-tokens`, `mlx_lm.server` defaults to **512** tokens, which a reasoning model will exhaust *inside* the thinking block and get cut off (`finish_reason: length`) before producing any answer — Open WebUI then shows only the thinking panel with an empty response. Set a generous `--max-tokens` for reasoners (e.g. `16384` for the in-depth model). For a model used for fast/direct answers, disable thinking entirely with `--chat-template-args '{"enable_thinking":false}'` so no token budget is spent on reasoning. See [Model only shows thinking, no answer](#model-only-shows-thinking-no-answer) in Troubleshooting.

### Recommended models (32GB RAM)

| Role | Model (Hugging Face repo) | Local path | Est. RAM | Port | Max Tokens | Thinking |
|---|---|---|---|---|---|---|
| Fast | `mlx-community/Qwen3-1.7B-4bit` | `/opt/models/qwen3-1.7b` | ~1GB | 8080 | 2048 | Off (`enable_thinking=false`) |
| In-Depth | `mlx-community/Qwen3.6-27B-OptiQ-4bit` | `/opt/models/qwen3.6-27b-optiq` | ~17.5GB + ~5GB KV cache @ 64k | 8081 | 16384 | Off (`enable_thinking=false`) |

Total estimated RAM if both are loaded: ~24 GB (on a 32 GB unified memory Mac Studio). The in-depth model's KV cache grows with context length — at the 64k context Hermes requires, budget ~5GB for it alone. If you see swap under concurrent Home Assistant + Hermes load, drop the fast model to `mlx-community/Qwen3-0.6B-4bit` (~300MB), or pause Open WebUI during heavy agent runs.

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

`docker/docker-compose.yml` configures Open WebUI with both local endpoints using:

- `OPENAI_API_BASE_URLS=http://host.docker.internal:8080/v1;http://host.docker.internal:8081/v1`
- `OPENAI_API_KEYS=none;none`

Open WebUI will discover both endpoints and expose model selection via the model picker per conversation. You can also manage endpoints in **Admin → Connections**.

---

## Per-app routing guide

| App | Endpoint | Reason |
|---|---|---|
| **Home Assistant** | `http://<HOST_IP>:8080/v1` | Fast, low-latency responses |
| **Open WebUI** | `:8081` default, `:8080` selectable | In-Depth for general chat, fast on demand |
| **Hermes Agent** | `http://<HOST_IP>:8081/v1` | In-Depth model (Qwen3.6-27B-OptiQ) for agent tool-calling — see [Hermes Agent integration](#hermes-agent-integration) |

---

## Hermes Agent integration

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is a self-improving AI agent by Nous Research. It works with any OpenAI-compatible endpoint, so the in-depth `mlx_lm.server` on `:8081` is a direct fit. The in-depth model (`mlx-community/Qwen3.6-27B-OptiQ-4bit`) is an OptiQ mixed-precision quant whose calibration mix explicitly includes tool-call and agent domains (BFCL-V3 function-calling score: 92.5%), making it a solid local choice for Hermes's tool-calling workflows.

> **Topology:** Hermes runs on a **separate host on the same LAN** as the Mac Studio. The MLX plists already bind `--host 0.0.0.0`, so `:8081` is reachable from other machines at `http://<MAC_STUDIO_IP>:8081/v1`. Find the Mac Studio's LAN IP with `ipconfig getifaddr en0` on the Mac Studio itself (the `status.sh` network summary prints it too).

### Firewall — allow LAN access to :8081

macOS's Application Firewall blocks incoming connections to `mlx_lm.server` by default. On a headless Mac Studio you won't see the allow dialog, so allow it explicitly once:

```bash
# On the Mac Studio (one-time):
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$(which mlx_lm.server)"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$(which mlx_lm.server)"
```

Or via GUI: System Settings → Network → Firewall → Options → add the `mlx_lm.server` binary and set to "Allow incoming connections". Verify from the Hermes host (not the Mac Studio):

```bash
# On the Hermes host — replace with the Mac Studio's LAN IP:
curl -s http://<MAC_STUDIO_IP>:8081/v1/models | python3 -m json.tool
# Expect: {"data": [{"id": "/opt/models/qwen3.6-27b-optiq", ...}]}
```

If that hangs or is refused, the firewall is still blocking — re-check the allowlist above. Note that the endpoint is **unauthenticated** (no API key); anyone on the LAN can send requests and consume RAM. That's acceptable on a trusted home LAN; on a shared network, restrict `:8081` to the Hermes host's IP via `pf` rules or a VPN.

### Install Hermes (on the Hermes host, not the Mac Studio)

```bash
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.zshrc
```

Hermes installs into `~/.hermes/` on the Hermes host and does not touch the Mac Studio's LaunchAgents or Docker containers.

### Point Hermes at the in-depth endpoint

```bash
hermes model
# → Select "Custom endpoint (self-hosted / VLLM / etc.)"
# → API base URL:  http://<MAC_STUDIO_IP>:8081/v1
# → API key:       (leave blank — local server needs none)
# → Model name:    /opt/models/qwen3.6-27b-optiq
```

Or set it directly:

```bash
hermes config set model.provider custom
hermes config set model.base_url http://<MAC_STUDIO_IP>:8081/v1
hermes config set model.default /opt/models/qwen3.6-27b-optiq
```

> **The model name must be the local path, not the repo ID.** `mlx_lm.server` reports the resolved `--model` path as the model ID on `/v1/models`, and on chat-completion requests it only short-circuits a reload if the incoming `model` field matches the loaded path (or the magic string `default_model`). If you send the repo ID `mlx-community/Qwen3.6-27B-OptiQ-4bit` instead, the server treats it as a new model and **downloads the 19GB model a second time** into the Hugging Face cache on the Mac Studio. The path is just a string identifier sent over HTTP — it does **not** need to exist on the Hermes host. See [Model ID is a local path](#model-id-is-a-local-path) in Troubleshooting.

### Context length requirement

Hermes **rejects** endpoints with under 64,000 tokens of context at startup — the system prompt, tool schemas, and working conversation state need the room. `mlx_lm.server` uses the model's native context window by default (Qwen3.6-27B supports 128k), so this is satisfied out of the box. Verify the endpoint is up and reports the in-depth model:

```bash
# On the Mac Studio:
curl -s http://localhost:8081/v1/models | python3 -m json.tool
# Expect an entry with "id": "/opt/models/qwen3.6-27b-optiq"
```

If you ever need to override the context length (run on the Hermes host):

```bash
hermes config set model.context_length 65536
```

### Why thinking is disabled on the in-depth model

The in-depth plist passes `--chat-template-args '{"enable_thinking":false}'`. Reasoning models emit a `…` block *before* the answer; in an agent loop that block can consume the entire token budget before a tool call is emitted, and the resulting tool-call JSON is often malformed. Hermes's own docs warn about this for Qwen/DeepSeek reasoners. Disabling thinking keeps tool calls clean and reliable — which is the priority here.

### Verify the integration

```bash
# 1. On the Mac Studio — endpoint up and serving the in-depth model:
curl -s http://localhost:8081/v1/models

# 2. On the Hermes host — reachable over the LAN (replace with the Mac Studio's IP):
curl -s http://<MAC_STUDIO_IP>:8081/v1/models

# 3. On the Hermes host — Hermes starts without rejecting the endpoint:
hermes

# 4. Run one simple tool-call turn in Hermes (e.g. ask it to list files
#    in the current directory) and confirm the tool call completes
#    end-to-end without a truncated/malformed response.
```

### Reliability notes for a 32GB Mac Studio

- **RAM is tight.** The 27B OptiQ weights (~17.5GB) plus a 64k KV cache (~5GB) plus the fast model (~1GB) plus macOS/Colima/Docker overhead (~4–6GB) sits at ~28–30GB. If Hermes is mid-conversation *and* Home Assistant fires simultaneously, you may hit swap. Mitigations: drop the fast model to `mlx-community/Qwen3-0.6B-4bit` (~300MB), or pause Open WebUI during heavy agent runs.
- **27B-OptiQ handles most agent loops reliably**, but self-improving skill creation and complex multi-step planning are weaker than frontier cloud models. Set expectations accordingly — this is a local-first tradeoff, not a Claude/GPT replacement.
- **No cloud fallback is configured.** This setup is intentionally local-only. If you later want hard agent tasks to fall through to a frontier model, Hermes supports fallback providers (OpenRouter, HuggingFace Inference Providers, Nous Portal) — see `hermes model`.
- **Hermes is off-host**, so Mac Studio reboots / LaunchAgent reloads will drop in-flight Hermes conversations. The MLX plists are `KeepAlive`, so the endpoint recovers automatically, but Hermes will need to retry its current turn.

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
| MLX indepth stdout | `/var/log/mlx/indepth.log` |
| MLX indepth stderr | `/var/log/mlx/indepth.error.log` |
| Colima stdout | `/var/log/mlx/colima.log` |
| Colima stderr | `/var/log/mlx/colima.error.log` |
| Docker Compose stdout | `/var/log/mlx/compose.log` |
| Docker Compose stderr | `/var/log/mlx/compose.error.log` |
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

The plists default to `/usr/local/bin/mlx_lm.server`. If `pipx` installed it elsewhere (commonly `~/.local/bin/`), update both plists:

```bash
MLX_PATH=$(which mlx_lm.server)
sed -i '' "s|/usr/local/bin/mlx_lm.server|$MLX_PATH|g" \
  ~/Library/LaunchAgents/com.mlx.fast.plist \
  ~/Library/LaunchAgents/com.mlx.indepth.plist
```

Verify:

```bash
grep -A3 "ProgramArguments" ~/Library/LaunchAgents/com.mlx.fast.plist
```

Then reload the agents:

```bash
for plist in com.mlx.fast com.mlx.indepth; do
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
hf download mlx-community/Qwen3.6-27B-OptiQ-4bit --local-dir /opt/models/qwen3.6-27b-optiq
```

### `mlx_lm.server` fails to load `Qwen3.6-27B-4bit` (wrong model variant)

The Hugging Face model `mlx-community/Qwen3.6-27B-4bit` is a **vision-language model** (tagged `Image-Text-to-Text`, converted with `mlx-vlm`). It will **not** load in `mlx_lm.server` — the server expects a text-only MLX model and will error at startup.

**Fix:** Use the text-only sibling `mlx-community/Qwen3.6-27B-OptiQ-4bit` instead (tagged `Text Generation`, loads via `from mlx_lm import load, generate`). This is the variant referenced throughout this README and the one Hermes integrates with. If you already downloaded the VLM by mistake:

```bash
rm -rf /opt/models/qwen3.6-27b   # remove the VLM
hf download mlx-community/Qwen3.6-27B-OptiQ-4bit --local-dir /opt/models/qwen3.6-27b-optiq
```

Then reload the in-depth LaunchAgent:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.mlx.indepth.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mlx.indepth.plist
```

### Model ID is a local path

The plists pass `--model /opt/models/<name>` (an on-disk path), so `mlx_lm.server` reports that path — not the Hugging Face repo ID — as the model ID on `/v1/models`:

```bash
curl -s http://localhost:8081/v1/models | python3 -m json.tool
# {"data": [{"id": "/opt/models/qwen3.6-27b-optiq", ...}]}
```

Any client (Open WebUI, Hermes, curl) must send this exact path in the `model` field of chat-completion requests. The server only short-circuits a model reload if the incoming `model` matches the loaded path (or the magic string `default_model`); any other value is treated as a new model path and **triggers a fresh download**.

**Symptom:** you point a client at the endpoint with `model: mlx-community/Qwen3.6-27B-OptiQ-4bit` (the repo ID) and the server starts downloading ~19GB into `~/.cache/huggingface/hub` even though the model is already loaded from `/opt/models/qwen3.6-27b-optiq`.

**Fix:** use the local path everywhere:
- Hermes: `hermes config set model.default /opt/models/qwen3.6-27b-optiq`
- Open WebUI: pick the `/opt/models/...` entry from the model picker (don't type a repo ID).
- curl: `-d '{"model":"/opt/models/qwen3.6-27b-optiq", ...}'`

### Port conflicts (8080/8081)

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
lsof -nP -iTCP:8081 -sTCP:LISTEN
```

Stop the conflicting process, then reload the affected LaunchAgent.

### Open WebUI cannot reach MLX servers

```bash
# From host
curl http://localhost:8080/v1/models
curl http://localhost:8081/v1/models

# From inside Open WebUI container
docker exec open-webui curl http://host.docker.internal:8080/v1/models
docker exec open-webui curl http://host.docker.internal:8081/v1/models
```

If container checks fail, verify this entry exists in `docker/docker-compose.yml`:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

### Open WebUI shows old/stale models

Open WebUI caches model records in its internal SQLite database (`webui.db`). Changing the model on an MLX server (by editing a plist and reloading the LaunchAgent) does **not** automatically update Open WebUI's cache — the model picker will still show the previous model ID.

**Detection:** run `./scripts/status.sh` and check the **Model Integrity** section. Green checkmarks mean the MLX servers and Open WebUI agree; a warning means drift was detected.

**Fix:** model sync runs automatically as part of `install.sh` and `update.sh`, but you can also trigger it manually:

```bash
./scripts/update.sh --mlx
```

This queries both MLX endpoints for their actual model IDs and updates Open WebUI's `model` table and `openai.api_configs` to match. Refresh your browser after the sync completes.

### Hermes (remote host) cannot reach the MLX servers

Hermes runs on a separate LAN host, so `localhost` won't work — it must use the Mac Studio's LAN IP. From the Hermes host:

```bash
# Replace with the Mac Studio's LAN IP (run `ipconfig getifaddr en0` on the Mac Studio):
curl -s http://<MAC_STUDIO_IP>:8081/v1/models
```

If this hangs or is refused but `curl http://localhost:8081/v1/models` works on the Mac Studio itself, the macOS Application Firewall is blocking inbound LAN traffic. Allow the `mlx_lm.server` binary once on the Mac Studio:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$(which mlx_lm.server)"
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblock "$(which mlx_lm.server)"
```

The MLX plists bind `--host 0.0.0.0`, so no change to the plists is needed — only the OS firewall. If you reload the LaunchAgent after a `mlx_lm.server` upgrade, re-add the new binary path (socketfilterfw keys on the executable path, which changes when pipx upgrades `mlx-lm`).

### Model only shows thinking, no answer

Open WebUI shows a **thinking** panel but the response is empty or missing. This affects reasoning models (Qwen3, Qwen3.6, etc.) when thinking is enabled.

**Cause:** Without `--max-tokens`, `mlx_lm.server` defaults to **512** generated tokens. A reasoning model emits its `…` block *first*; on any non-trivial prompt it spends all 512 tokens inside the thinking block and is cut off (`finish_reason: length`) before emitting the closing `` and the actual answer. Open WebUI then renders the partial thinking with no answer text.

**Fix:** Add `--max-tokens` to the affected plist in `~/Library/LaunchAgents/` (e.g. `16384` for the in-depth Qwen3.6-27B model, `2048` for the fast Qwen3-1.7B model). For a model meant to give fast/direct answers (or for agent tool-calling where a thinking block can eat the budget before a tool call), also disable the thinking block:

```xml
<string>--max-tokens</string>
<string>16384</string>
<string>--chat-template-args</string>
<string>{"enable_thinking":false}</string>
```

Then reload the agent:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.mlx.<role>.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mlx.<role>.plist
```

**Confirm** the model now finishes its answer — `finish_reason` should be `stop` (not `length`) and `content` should be non-empty:

```bash
curl -s http://localhost:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"/opt/models/qwen3.6-27b-optiq","messages":[{"role":"user","content":"Explain TCP vs UDP thoroughly."}]}' \
  | python3 -c "import sys,json; c=json.load(sys.stdin)['choices'][0]; print(c['finish_reason'], len(c['message'].get('content','') or ''))"
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

### `docker` CLI missing after a Homebrew upgrade

A `brew upgrade` can leave the `docker` formula installed in the Cellar but unlinked from `/opt/homebrew/bin/` (often because `docker-completion` owns conflicting completion symlinks). `status.sh` then reports every container as "not found" and SearXNG as "not responding" even though the stack is healthy.

Fix:

```bash
brew link --overwrite docker
```

Verify:

```bash
which docker          # → /opt/homebrew/bin/docker
docker version
```

---

## Repository Structure

```
local-llm-mac-studio/
├── README.md
├── launchagents/
│   ├── com.mlx.fast.plist
│   ├── com.mlx.indepth.plist
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
