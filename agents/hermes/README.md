# Hermes for a friend (containerized)

A self-contained [Hermes Agent](https://github.com/NousResearch/hermes-agent) that a friend talks to from their own Telegram, with a web dashboard on this Mac for you. It uses the official `nousresearch/hermes-agent` image and is fully separate from:

- the repo-root `docker-compose.yml` (its own compose project, `hermes-friend`, and its own networks);
- the Hermes app and gateway installed on this host (`~/.hermes`): different data, different bot, different ports.

The LLM is **Kimi K2.6 on Venice AI** (`e2ee-kimi-k2-6`), the same provider block as the host's `tezcatlipoca` profile, and it is [locked to that model](#locked-to-one-model). Web search and page fetching work [the same way as on tezcatlipoca](#web-search-and-fetch) (Brave + Tavily). It does not use the local LM Studio, and it can't reach it (see [Network isolation](#network-isolation)). Her persona, memories and chats [never go to git](#privacy-what-stays-out-of-git).

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
| `hermes-friend-seed` | One-shot: copies `config/*` into the data volume, then exits `0`. | none |

## Files

| Path | Purpose | In git |
|---|---|---|
| `docker-compose.yml` | All services above. | yes |
| `config/config.yaml` | Hermes config: model/provider, tools, memory. Generic, nothing private. | yes |
| `config/SOUL.md` | Optional persona for her bot. Create it and it's copied in like `config.yaml`. | **no**, ignored |
| `config/*` (anything else) | Copied into the volume too. | **no**, ignored |
| `managed/config.yaml` | Pinned settings she and the agent can't change: model, web backends, Telegram slash commands. Mounted read-only at `/etc/hermes`. | yes |
| `egress/squid.conf` | Egress policy: public internet yes; this Mac, LAN and tailnet no. | yes |
| `.env` | Secrets: Venice, Brave and Tavily keys, bot token, allowed users, dashboard login. | **no** |
| `.env.example` | Template for `.env`. | yes |

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
   Set `BRAVE_SEARCH_API_KEY` and `TAVILY_API_KEY` for web search and page fetching (see [Web search and fetch](#web-search-and-fetch)).
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

Backups cover those cases. The friend's agent is backed up to the NAS by the same nightly job as your other Hermes agents: [`hermes-backup.sh`](../../../nas/scripts/hermes-backup/README.md) in `~/repos/nas`, at 01:00. It exports the volume through a throwaway container (no network), then gives it the same treatment as the others:

- It copies only the agent (config, `.env`, SOUL, memories, skills, chat history in `state.db`), with consistent SQLite snapshots.
- A night with no changes writes nothing.
- It refuses to overwrite a good copy with a blank or reset agent.
- Failures alert on Discord, including when Docker Desktop isn't running at 01:00.

What is **not** backed up: the agent's `workspace/` (files it created for her), the same as for the host's profiles. Caches and logs aren't backed up either.

**One-time install:** the container support is new in `hermes-backup.sh` (2026-10-25), and the nightly job runs the installed copy in `/usr/local/sbin`. Until you reinstall it, her agent isn't backed up:

```bash
sudo install -m 755 -o root -g wheel ~/repos/nas/scripts/hermes-backup/hermes-backup.sh /usr/local/sbin/
```

Then trigger a run to confirm it. Expect `[hermes-friend] copied to …`:

```bash
sudo launchctl kickstart -k system/local.hermes-backup && sleep 15 && tail -5 /var/log/hermes-backup.log
```

The copy is in `/Volumes/tank/documents/hermes/containers/hermes-friend/current`. Older versions come from tank's snapshots (7 daily, 4 weekly, 6 monthly) and the off-site copy. The job works while the stack is down too, as long as Docker Desktop runs.

Check the last copy:

```bash
cat /Volumes/tank/documents/hermes/containers/hermes-friend/current/MANIFEST
```

Restore. This overwrites the volume's copies of those files. Pick `current` or a snapshot under `/Volumes/tank/documents/.zfs/snapshot/*/hermes/containers/hermes-friend/current`:

```bash
cd ~/repos/local_llm/agents/hermes
docker compose down
docker run --rm --network none --user 0:0 -v hermes-friend_hermes-data:/opt/data \
  -v /Volumes/tank/documents/hermes/containers/hermes-friend/current:/restore:ro \
  --entrypoint sh nousresearch/hermes-agent:v0.22.5 -c \
  'find /opt/data -maxdepth 2 \( -name "*.db-wal" -o -name "*.db-shm" \) -delete &&
   cd /restore && tar -cf - --exclude=MANIFEST . | tar -xf - -C /opt/data && chown -R 10000:10000 /opt/data'
docker compose up -d
```

Use the image tag from the copy's MANIFEST. The `find … -delete` matters: a leftover `state.db-wal` from the old database would be replayed into the restored one and corrupt it.

Why a named volume and not a folder here: on Docker Desktop for Mac, bind mounts use virtiofs. There Hermes can't set its gateway socket to mode 600, so local chat refuses to connect, and SQLite in WAL mode can corrupt `state.db`.

## Changing the config

`config/config.yaml` is the source of truth. On every `docker compose up`, the one-shot `seed` service copies everything in `config/` into the volume, overwriting what's there. So:

- **Edit `config/config.yaml`, then `docker compose up -d`.** If only the config changed, `up` won't recreate `hermes`, so also run `docker compose restart hermes`.
- Changes made in the dashboard's **Config** page work, but they're lost the next time you run `up`. Copy anything you want to keep back into `config/config.yaml`.
- Settings in `managed/config.yaml` (model, web backends, slash-command access) win over everything here and can't be changed from the dashboard. Edit that file and run `docker compose restart hermes`.
- API keys saved in the dashboard's **Keys** page go into Hermes' own `.env` inside the volume and are not overwritten. Values set in this folder's `.env` take precedence over them.

## Locked to one model

Only Venice's `e2ee-kimi-k2-6` runs here. Neither your friend nor the agent can switch it:

- **Managed scope.** [`managed/config.yaml`](managed/config.yaml) is mounted read-only at `/etc/hermes`, Hermes' managed-config location. Its values win over `config.yaml`, the dashboard and `hermes config set`. It pins:
  - the model and the Venice provider;
  - no fallback models;
  - subagents (`delegation`) on the same model;
  - Mixture of Agents off.

  `hermes config set model.default …` inside the container answers *"it is managed by your administrator"*. Writing to the file fails with *Read-only file system*, even as root in the container.
- **Telegram slash-command gating.** Without it, `/model` in Telegram switches the model for a chat. The admin list is set to `"0"`, which matches no Telegram user, so every allowed user is a non-admin and can run only `user_allowed_commands` plus `/help` and `/whoami`. Allowed: `/start /new /retry /undo /stop /title /status /context /usage /sessions /resume /save /compress /btw /queue /steer /voice /approve /deny /memory /commands`. Blocked include:
  - `/model`, `/reasoning`, `/fast`, `/moa`: other models, or more spend per message;
  - `/loop`, `/heartbeat`, `/goal`, `/bg`: unattended spend;
  - `/yolo`, `/approvals`, `/personality`;
  - every admin or debug command (`/debug` uploads logs).

  Verified by resolving the live policy for her ID: `/model`, `/reasoning` and `/debug` are denied; `/new`, `/start` and `/approve` are allowed. She can send `/whoami` to see her own access.

To change any of this, edit `managed/config.yaml` and run `docker compose restart hermes`.

One gap Hermes can't close: the Venice key is in the container, so a determined user could call Venice directly with another model (see [Things to know](#things-to-know)). The spending limit on her Venice key is the backstop.

## Web search and fetch

Same backends as tezcatlipoca, pinned in `managed/config.yaml`:

- `web.backend: brave-free` for search, with `BRAVE_SEARCH_API_KEY`;
- `web.extract_backend: tavily` for reading pages, with `TAVILY_API_KEY`;
- `web.use_gateway: false`.

Both keys go in `.env`. They are currently **copies of tezcatlipoca's keys**, so her searches count against your Brave and Tavily quotas. If she uses up a free tier, tezcatlipoca's search stops working too. Get her free keys of her own ([Brave Search API](https://brave.com/search/api/), [Tavily](https://tavily.com)), put them in `.env`, then run `docker compose up -d`.

Both APIs are public internet, so the egress proxy lets them through. Verified end to end: a question that needed a search and a page read went to `api.search.brave.com` and `api.tavily.com`, and the answer quoted the fetched page.

## Privacy: what stays out of git

Her bot's persona, memories and conversations are private and never go to GitHub:

- **Persona:** `config/SOUL.md`, and anything else in `config/` except the generic `config.yaml`, is git-ignored (see `.gitignore`). It only exists on this Mac and, once copied into the volume, in the NAS backup.
- **Memories and chat history:** they exist only inside the Docker volume (`memories/`, `state.db`, `sessions/`), never in this folder. The only copies are on the NAS: `tank/documents`, its snapshots, and the encrypted off-site copy.
- **Secrets:** `.env` is git-ignored.

Before committing anything in this folder, `git status` should list only tracked files: `docker-compose.yml`, `config/config.yaml`, `managed/config.yaml`, `egress/squid.conf`, `.env.example`, `.gitignore` and `README.md`.

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

- **A determined user can extract the keys inside the container.** Tested: Hermes strips most of them (Brave, Tavily, bot token, dashboard password) from the shell tool's environment. The Venice key still shows there, because a custom provider's `key_env` isn't on Hermes' strip list. Either way, all four keys can be read from the gateway process's own environment (`/proc/<pid>/environ`) by anything running as the agent's user. Treat every key here as visible to her. That's why her Venice key is separate and capped, and why she should get her own Brave and Tavily keys. Your other secrets (`~/.hermes`, the repo-root `.env`) are not in the container.
- **Cost.** Every message your friend sends is billed to the Venice account behind `VENICE_API_KEY`.
- **The internet is open.** The proxy blocks your Mac, LAN and tailnet, not the public web. That's needed for search, fetch and browsing. To restrict it further, add a `dstdomain` allowlist in `egress/squid.conf`.
- **Never mount `~/.hermes`** into this container. Two gateways sharing one data dir corrupt sessions and memory.
