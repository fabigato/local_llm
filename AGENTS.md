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
- **ComfyUI is exposed remotely via Tailscale Serve, not nginx** (`tailscale serve --bg --https=8443 8188`, tainet-only). The URL is `https://<node>.<tailnet>.ts.net:8443` — **note the port**; `:8188` is the proxy target, not a listen port, and browsing to `:8188` just times out. Serve sits on 8443 rather than the default 443 because Docker's dual-stack `*:443` (nginx) steals host-local connections and returns the wrong cert; on 8443 you *can* test from the serving Mac. ComfyUI stays bound to `127.0.0.1:8188`; do NOT rebind it to `0.0.0.0`/`100.x` or the containers/LAN assumptions break. See the README "Exposing ComfyUI remotely" section.
- **ComfyUI runs as a LaunchDaemon** (`com.local.comfyui`), not the Comfy Desktop app — Desktop was a Login Item, so nothing served after an unattended reboot. Desktop **cannot** attach to the running backend; launching its managed instance fights the daemon over port 8188. Use a Remote Connection instance, or stop the daemon first. See [comfyui/launchd/README.md](comfyui/launchd/README.md).

## Commands
- Logs: `docker logs -f openclaw` (filter: `| grep -iE 'comfy|image-generation|error'`)
- Restart one service: `docker restart openclaw`
- Recreate after `.env` change: `docker compose up -d --force-recreate openclaw`

## Conventions
- Secrets go in a git-ignored `.env` (see `.env.example`); never hardcode them in `openclaw.json` — reference `${VARS}`.
- When editing exported ComfyUI API workflows (`comfyui/api/*.json`), link the file when you mention it and note node IDs you touch.
