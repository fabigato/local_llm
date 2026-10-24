# Hermes for a friend (containerized)

A self-contained [Hermes Agent](https://github.com/NousResearch/hermes-agent) that a friend talks to from their own Telegram, with a web dashboard on this Mac for you. It uses the official `nousresearch/hermes-agent` image and is fully separate from:

- the repo-root `docker-compose.yml` (its own compose project, `hermes-friend`, and its own networks);
- the Hermes app and gateway installed on this host (`~/.hermes`): different data, different bot, different ports.

The LLM is **Kimi K2.6 on Venice AI** (`e2ee-kimi-k2-6`), the same provider block as the host's `tezcatlipoca` profile. It does not use the local LM Studio, and it can't reach it (see [Network isolation](#network-isolation)).

## Ports and endpoints

| What | Host address | Notes |
|---|---|---|
| Web dashboard | <http://127.0.0.1:9120> | Loopback only. Login required (`HERMES_DASHBOARD_USERNAME` / `_PASSWORD` from `.env`). Change the host port with `HERMES_DASHBOARD_HOST_PORT`. |
| Dashboard status (no login) | `http://127.0.0.1:9120/api/status` | JSON: version, gateway state, connected platforms. |
| Telegram | none | Long polling: the container connects out to Telegram, nothing listens. |

Nothing else is published. The host's own Hermes keeps its defaults (dashboard 9119, API server 8642), so nothing here collides with it.

The dashboard is the browser counterpart of the Hermes app. **Chat** runs the full Hermes TUI in the page, with a session list and model picker. **Sessions** shows every conversation, including your friend's Telegram ones. There are also pages for Config, API keys, Skills, Memory, Cron, Logs and Analytics.

## Containers

| Container | Role | Networks |
|---|---|---|
| `hermes-friend` | Gateway (Telegram) and dashboard, supervised by s6. | `agent` only (internal, no route out) |
| `hermes-friend-egress` | Squid proxy. Hermes' only way out. | `agent` + `edge` |
| `hermes-friend-dashboard` | socat forwarder that publishes the dashboard on `127.0.0.1:9120`. | `agent` + `edge` |
| `hermes-friend-backup` | Runs `hermes backup` into `./backups` at start, then every N hours. | none |
| `hermes-friend-seed` | One-shot: copies `config/*` into the data volume, then exits `0`. | none |

## Files

| Path | Purpose | In git |
|---|---|---|
| `docker-compose.yml` | All services above. | yes |
| `config/config.yaml` | Hermes config: model/provider, tools, memory. | yes |
| `config/SOUL.md` | Optional persona. Create it and it's copied in like `config.yaml`. | if you add it |
| `egress/squid.conf` | Egress policy: public internet yes; this Mac, LAN and tailnet no. | yes |
| `.env` | Secrets: Venice key, bot token, allowed users, dashboard login. | **no** |
| `.env.example` | Template for `.env`. | yes |
| `backups/` | Backup zips. They contain the friend's full history **and** Hermes' own `.env`. | **no** |

## First-time setup

1. **Create a Telegram bot.** You can do this yourself; your friend doesn't need to. In Telegram, message [@BotFather](https://t.me/BotFather), send `/newbot`, and copy the token. Use a new bot. Don't reuse the host Hermes or openclaw bot: two processes polling one token steal each other's messages. You'll own the bot (rename it, change the avatar or revoke the token via BotFather), and your friend just chats with it.
2. **Get your friend's Telegram user ID.** Ask them to message [@userinfobot](https://t.me/userinfobot) and send you the number. Only IDs in `TELEGRAM_ALLOWED_USERS` get answers.
3. **Fill in `.env`:**
   ```bash
   cd ~/repos/local_llm/agents/hermes
   cp .env.example .env && chmod 600 .env   # skip if .env already exists
   ```
   Set `VENICE_API_KEY`, `TELEGRAM_BOT_TOKEN` and `TELEGRAM_ALLOWED_USERS`, then generate the dashboard password and secret:
   ```bash
   openssl rand -base64 24   # HERMES_DASHBOARD_PASSWORD
   openssl rand -base64 32   # HERMES_DASHBOARD_SECRET
   ```
   Optionally set `BRAVE_SEARCH_API_KEY` to enable web search.
4. Start it (next section), then send your friend the bot's `t.me/<botname>` link and have them press **Start**.

## Run, stop, and maintain

Run all of these from `~/repos/local_llm/agents/hermes`.

| Task | Command |
|---|---|
| Start, or apply `.env`/config changes | `docker compose up -d` |
| Stop (keeps all data) | `docker compose down` |
| Restart Hermes | `docker compose restart hermes` |
| Status | `docker compose ps -a` |
| Logs (gateway + dashboard) | `docker logs -f hermes-friend` |
| Hermes' own logs | `docker exec hermes-friend hermes logs --follow` |
| What it connected to / was refused | `docker exec hermes-friend-egress tail -f /var/log/squid/access.log` |
| Health check | `docker exec hermes-friend hermes doctor` |
| One-off chat from the terminal | `docker exec -it hermes-friend hermes` |
| Upgrade | Bump `HERMES_IMAGE_TAG` in `.env`, then `docker compose pull && docker compose up -d` |

Quick start:

```bash
cd ~/repos/local_llm/agents/hermes && docker compose up -d
```

Stop:

```bash
cd ~/repos/local_llm/agents/hermes && docker compose down
```

Check it's healthy. Expect `gateway_state: running` and `telegram` among the platforms:

```bash
curl -s http://127.0.0.1:9120/api/status | python3 -m json.tool | grep -E '"(version|gateway_state|state)"|telegram'
```

## Persistence and backups

All state (chats, memory, skills, Hermes' own `.env`) lives in the Docker volume `hermes-friend_hermes-data`, mounted at `/opt/data`. A volume lives independently of the container. It survives crashes, `restart`, `down`/`up`, image upgrades, and Docker Desktop or Mac restarts.

It is **lost** only by:

- `docker compose down -v`
- `docker volume rm` / `docker volume prune`
- Docker Desktop's *Clean / Purge data* or *Reset to factory defaults*, or uninstalling Docker Desktop

Backups cover those cases. The `backup` container runs `hermes backup` (consistent SQLite snapshots) when it starts and then every `HERMES_BACKUP_INTERVAL_HOURS` (default 24). It writes `backups/hermes-backup-<timestamp>.zip` and keeps the newest `HERMES_BACKUP_KEEP` (default 14). `backups/` is an ordinary folder on your Mac, so Time Machine picks it up too.

Take a backup right now:

```bash
docker compose run --rm --no-deps --entrypoint /opt/hermes/.venv/bin/hermes backup backup -o /backups
```

Restore one. This overwrites current state with the zip's contents:

```bash
docker compose stop hermes backup
docker compose run --rm --no-deps --entrypoint /opt/hermes/.venv/bin/hermes backup import --force /backups/hermes-backup-<timestamp>.zip
docker compose up -d
```

Why a named volume and not a folder here: on Docker Desktop for Mac, bind mounts use virtiofs. There Hermes can't set its gateway socket to mode 600, so local chat refuses to connect, and SQLite in WAL mode can corrupt `state.db`.

## Changing the config

`config/config.yaml` is the source of truth. On every `docker compose up`, the one-shot `seed` service copies everything in `config/` into the volume, overwriting what's there. So:

- **Edit `config/config.yaml`, then `docker compose up -d`.** If only the config changed, `up` won't recreate `hermes`, so also run `docker compose restart hermes`.
- Changes made in the dashboard's **Config** page work, but they're lost the next time you run `up`. Copy anything you want to keep back into `config/config.yaml`.
- API keys saved in the dashboard's **Keys** page go into Hermes' own `.env` inside the volume and are not overwritten. Values set in this folder's `.env` take precedence over them.

## Network isolation

Anyone in `TELEGRAM_ALLOWED_USERS` can make the agent run shell commands and fetch URLs. A web page the agent reads can also try to steer it (prompt injection). Those commands run inside the container, not on your Mac. But a normal container can still reach every service on this Mac through `host.docker.internal`, and some have no auth. Tested from a container on this machine before the lockdown:

| Service | Reachable? | What it exposed |
|---|---|---|
| Hindsight `:8888` | yes, no auth | Your memory banks: `GET /v1/default/banks`, and recall on them. |
| ComfyUI `:8188` | yes, no auth | Full prompt history and output images (`/history`, `/view`), plus queueing jobs. |
| LM Studio `:1234` | yes, no auth | Free inference, and loading/unloading models. |
| openclaw `:18789`, Ollama `:11434`, Open WebUI `:3000`, other local ports | yes | Varies. Some have auth, some don't. |
| LAN (router, NAS) and tailnet | yes | Whatever answers there. |

So `hermes` runs on an **internal-only** Docker network with no route to anything. Its only way out is the `egress` Squid proxy. The proxy allows ports 80/443 to the public internet and refuses any destination that **resolves** to a private, loopback, link-local, CGNAT/Tailscale (`100.64.0.0/10`) or Docker Desktop address. Hostnames like `host.docker.internal`, or a DNS name pointed at `192.168.x.x`, are refused too. Verified after the change:

- `api.venice.ai`, `api.telegram.org`, `example.com` → allowed
- Hindsight, ComfyUI, LM Studio, openclaw, `192.168.1.1`, `100.100.100.100` → `403` from the proxy
- Bypassing the proxy (`curl --noproxy '*'`) → no route

Re-run the check any time:

```bash
docker exec hermes-friend sh -c 'for u in https://api.venice.ai/api/v1/models http://host.docker.internal:8888/ http://host.docker.internal:8188/history http://192.168.1.1/; do printf "%-45s " $u; curl -s -o /dev/null -m 8 -w "%{http_code}\n" $u; done'
```

Expect `200` for the first URL and `403` for the rest.

## Things to know

- **Your friend can see the keys inside the container.** The Venice key and bot token are environment variables there, so a determined user could extract them with the terminal tool. Hermes masks them in output, but don't rely on that. Give this container **its own Venice API key with a spending limit**, not the tezcatlipoca one, so you can cap or revoke it alone. Your other secrets (`~/.hermes`, the repo-root `.env`) are not in the container.
- **Cost.** Every message your friend sends is billed to the Venice account behind `VENICE_API_KEY`.
- **The internet is open.** The proxy blocks your Mac, LAN and tailnet, not the public web. That's needed for search, fetch and browsing. To restrict it further, add a `dstdomain` allowlist in `egress/squid.conf`.
- **Never mount `~/.hermes`** into this container. Two gateways sharing one data dir corrupt sessions and memory.
