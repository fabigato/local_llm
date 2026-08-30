# AGENTS.md

Guidance for AI agents working in this repo. Keep it lean; the [README](README.md) holds the detail.

## What this is
A self-hosted local-LLM stack, orchestrated by `docker-compose.yml`. No app code — it's config, workflows, and docs. Services (container : host→container ports):
- **open-webui** `open-webui` — chat UI, `3000:8080`
- **nginx** `nginx` — reverse proxy / TLS, `80`, `443`
- **openclaw** `openclaw` — agent gateway (Telegram bot + HTTP API), `18789`, `18790`. Its config lives in `.openclaw/openclaw.json` (mounted, gitignored).
- **hindsight** `hindsight` — episodic memory engine, `8888`, `9999`
- LLMs are served by **ollama** running on the host (not a compose service), reached via `host.docker.internal:11434`.
- **ComfyUI** is external too (host `:8188`), used for image generation/editing. See the ComfyUI section in the README.

## Key facts / gotchas (not obvious from the code)
- The "agent" that misbehaves in chat is the **local model inside openclaw** (an ollama Qwen), not the host tooling. Don't trust its self-diagnosis — read logs.
- **comfy config changes need a full `docker restart openclaw`.** Openclaw logs a "hot reload applied" for `plugins.entries.comfy.config.*`, but the comfy provider keeps the old config until restarted.
- **open-webui env vars in `docker-compose.yml` are seed-only.** Most settings are *PersistentConfig*: stored in `webui.db` and the DB wins at boot, so those vars only take effect on a fresh volume. Change them in the admin UI, not in compose. Never set `ENABLE_PERSISTENT_CONFIG=False` — it makes every boot ignore the DB, which silently wipes UI-only config (ComfyUI image gen, whisper STT) on each restart while env-backed and per-model settings survive. See the README "A note on open webui configuration env vars".
- **SSRF guard:** openclaw only reaches ComfyUI when `baseUrl` is a *literal private IP* (e.g. `192.168.65.254` on Docker Desktop, `172.17.0.1`-ish on Linux), never `host.docker.internal`. Wired via `OPENCLAW_COMFY_BASE_URL`.
- The comfy plugin has **one image-workflow slot** shared by generate + edit; editing needs `inputImageNodeId` set. The hybrid workflow relies on a `blank.png` placeholder in ComfyUI's `input/`.
- **`Comfy workflow did not finish within Ns` is almost never ComfyUI's fault — it's the poll budget.** The plugin submits the prompt then polls `/history/<prompt_id>`, and its budget is `plugins.entries.comfy.config.image.timeoutMs` → the agent's `timeoutMs` tool argument → 300s default. The local Qwen *invents* that argument and ratchets it **down** after each failure (observed: 70s → 60s → 50s → 45s → 30s), while the qwen-edit workflow really takes **~7 min** on this box (`curl -s 'localhost:8188/history?max_items=5'` → `dur_s= 409`). Config wins over the tool argument, so pin `timeoutMs` there (currently 900000) and ignore whatever the model asks for. Abandoned jobs keep running to completion in ComfyUI and the next attempt queues behind them, so short budgets snowball; check `localhost:8188/queue` before retrying. Identical prompt+seed+input is a Comfy cache hit (`dur_s= 0.002`) — a "fast success" is a replay of earlier outputs, not proof the timeout is fine.
- **Background media completions can be delivered to Telegram and still be lost from the transcript.** The send succeeds (`outbound send ok … messageId=…`), then the post-send commit mirrors the message into the session `.jsonl` — and that write loses a race with the running agent turn, failing as either `session file locked (timeout 60000ms): pid=8` or `session file changed while embedded prompt lock was released`. The entry stays unacked in `send_attempt_started` and lands in `.openclaw/delivery-queue/failed/`; the drain then logs `refusing blind replay without adapter reconciliation` and gives up — correctly, since the Telegram adapter declares no `durableFinal.reconcileUnknownSend`, so nothing can ask Telegram whether the message went out. Visible symptom: `Media generation completion wake failed; requester session was not woken` — the user got the image/error but the agent has no idea, so it may claim failure or silently drop a finished image. Mitigated by `session.writeLock.acquireTimeoutMs` (raised to 240000; default 60000 is shorter than a slow local-model turn, and the lock watchdog force-releases at `maxHoldMs`=300000 anyway, so waiting past that buys nothing). Don't set it to tens of minutes: the same timeout gates inbound messages reporting "session busy".
- **ComfyUI is exposed remotely via Tailscale Serve, not nginx** (`tailscale serve --bg --https=8443 8188`, tainet-only). The URL is `https://<node>.<tailnet>.ts.net:8443` — **note the port**; `:8188` is the proxy target, not a listen port, and browsing to `:8188` just times out. Serve sits on 8443 rather than the default 443 because Docker's dual-stack `*:443` (nginx) steals host-local connections and returns the wrong cert; on 8443 you *can* test from the serving Mac. ComfyUI stays bound to `127.0.0.1:8188`; do NOT rebind it to `0.0.0.0`/`100.x` or the containers/LAN assumptions break. See the README "Exposing ComfyUI remotely" section.
- **A half-broken ComfyUI UI over the Tailnet URL (but fine on `127.0.0.1`) is a file-descriptor limit, not a proxy bug.** Tailscale Serve speaks HTTP/2, so a browser fires the whole page concurrently down one connection; ComfyUI runs out of descriptors and **aiohttp reports a failed `open()` as `404`**, so core frontend chunks look "missing" and the app misbehaves (workflows won't open, `changeTracker` errors). Fixed by `SoftResourceLimits/NumberOfFiles` in the daemon plist — launchd's default is 256. See [comfyui/launchd/README.md](comfyui/launchd/README.md).
- **ComfyUI runs as a LaunchDaemon** (`com.local.comfyui`), not the Comfy Desktop app — Desktop was a Login Item, so nothing served after an unattended reboot. Desktop **cannot** attach to the running backend; launching its managed instance fights the daemon over port 8188. Use a Remote Connection instance, or stop the daemon first. See [comfyui/launchd/README.md](comfyui/launchd/README.md).

## Commands
- Logs: `docker logs -f openclaw` (filter: `| grep -iE 'comfy|image-generation|error'`)
- Restart one service: `docker restart openclaw`
- Recreate after `.env` change: `docker compose up -d --force-recreate openclaw`

## Conventions
- Secrets go in a git-ignored `.env` (see `.env.example`); never hardcode them in `openclaw.json` — reference `${VARS}`.
- When editing exported ComfyUI API workflows (`comfyui/api/*.json`), link the file when you mention it and note node IDs you touch.
