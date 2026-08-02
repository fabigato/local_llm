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
- **SSRF guard:** openclaw only reaches ComfyUI when `baseUrl` is a *literal private IP* (e.g. `192.168.65.254` on Docker Desktop, `172.17.0.1`-ish on Linux), never `host.docker.internal`. Wired via `OPENCLAW_COMFY_BASE_URL`.
- The comfy plugin has **one image-workflow slot** shared by generate + edit; editing needs `inputImageNodeId` set. The hybrid workflow relies on a `blank.png` placeholder in ComfyUI's `input/`.
- **ComfyUI is exposed remotely via Tailscale Serve, not nginx** (`tailscale serve --bg 8188` → `https://<node>.<tailnet>.ts.net`, tainet-only). It stays bound to `127.0.0.1:8188`; do NOT rebind it to `0.0.0.0`/`100.x` or the containers/LAN assumptions break. You **can't test the tainet URL from the serving Mac** — Docker's dual-stack `*:443` (nginx) grabs host-local connections to the tainet IP and returns the wrong cert; verify from another tainet device. See the README "Exposing ComfyUI remotely" section.

## Commands
- Logs: `docker logs -f openclaw` (filter: `| grep -iE 'comfy|image-generation|error'`)
- Restart one service: `docker restart openclaw`
- Recreate after `.env` change: `docker compose up -d --force-recreate openclaw`

## Conventions
- Secrets go in a git-ignored `.env` (see `.env.example`); never hardcode them in `openclaw.json` — reference `${VARS}`.
- When editing exported ComfyUI API workflows (`comfyui/api/*.json`), link the file when you mention it and note node IDs you touch.
