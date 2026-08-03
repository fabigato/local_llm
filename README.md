# Local LLM
An (almost) fully containerized local llm system, relying on a locally installed ollama and then the rest is all managed by docker.

## Design principles
- **reproducibility**: docker first approach. Anything that can be configured in docker compose will be configured there, relying on service specific configuration files only when docker compose is impossible or too inconvenient
- **privacy**: local models first
- **secret managegement**: no secrets commited, ever. Use .env file to inject values into the docker compose and from there into any service specific config files
- **multi tenancy**: system allows multiple users when possible. Features such as memory have to respect this

# Services
## nginx
Reverse proxy to forward incoming traffic to the exposed services. This handles SSL, so https traffic ends here, after nginx, open webui sees only http requests. Encryption is managed by letsencrypt, a certbot docker image is used to request and renew ssl certificates.

**One wildcard certificate, one subdomain per service.** A single cert covers `${DOMAIN}` and `*.${DOMAIN}`, so every service gets its own hostname instead of sharing one behind a path prefix:

| URL | Service |
| --- | --- |
| `https://chat.${DOMAIN}` | Open WebUI |
| `https://whisper.${DOMAIN}` | whisper transcription API |
| `https://llm.${DOMAIN}` | ollama API |

Because the cert already covers any subdomain, **adding a service needs no certificate work at all** — write a template, add a DNS record, recreate nginx. `ssl_certificate` is therefore declared once at `http` level in [nginx/nginx.conf](nginx/nginx.conf) and inherited by every server block, rather than repeated per server.

### Editing the nginx config (templates)
The active config isn't edited directly. The files under `nginx/templates/*.template` are rendered into `/etc/nginx/conf.d/*.conf` by the official nginx image's entrypoint, which runs `envsubst` (this is how `${DOMAIN}` gets substituted from the environment). Crucially, **this rendering happens only once, at container startup.**

One file per concern, and the numeric prefixes control load order (`include conf.d/*.conf` is alphabetical):

| Template | Contains |
| --- | --- |
| `00-whisper.conf.template` | whisper's http-context bits: bearer `map`, `log_format`, rate-limit zone |
| `01-ollama.conf.template` | the same for ollama |
| `05-default.conf.template` | `:80` → `:443` redirect, plus `default_server` catch-alls |
| `10-chat.conf.template` | `chat.${DOMAIN}` → Open WebUI |
| `11-whisper.conf.template` | `whisper.${DOMAIN}` → whisper |
| `12-llm.conf.template` | `llm.${DOMAIN}` → ollama |

Note `nginx.conf` itself is **not** a template — it's mounted verbatim, so it can't reference `${DOMAIN}`. That's why the certificate is issued under the fixed name `wildcard` (`certbot --cert-name wildcard`): it gives `nginx.conf` a domain-independent path to point at.

That means `docker compose exec nginx nginx -s reload` is **not** enough after editing a template: reload only re-reads the already-rendered `.conf` files in `conf.d/`, it does not re-run `envsubst`. To pick up template changes you have to recreate (or restart) the container so the entrypoint renders them again:
```
docker compose up -d --force-recreate nginx
```
You can verify what actually landed in the live config with:
```
docker exec nginx cat /etc/nginx/conf.d/10-chat.conf
```
(Example gotcha: adding `client_max_body_size 100M;` to fix a 413 on uploads only takes effect after the recreate — a plain reload leaves the old 1MB default in place. This error was particularly obscure in open webui browser since it only complained about some non well formed json. This happened because nginx send an html error to open webui. To see what was going on you had to go to the broser's developer view on the network tab and reproduce the error, verifying the url was returning a 413 due to content size too large)

### DNS on a dynamic IP (ddclient + CNAMEs)
This host has no static IP, so `ddclient` keeps the records pointing at it. It runs from `/Library/LaunchDaemons/homebrew.mxcl.ddclient.plist` with `StartInterval 300` and no `-daemon` flag, so it fires every 5 minutes and exits — **seeing no `ddclient` process in `ps` is normal**, not a failure. Config lives at `/opt/homebrew/etc/ddclient/ddclient.conf` (root-owned, mode 600).

**ddclient maintains exactly one name: the apex.** Everything else is a CNAME to it:

| Name | Type | Value |
| --- | --- | --- |
| `<DOMAIN>` (apex) | A + AAAA | updated by ddclient |
| `chat` | CNAME | `<DOMAIN>.` |
| `whisper` | CNAME | `<DOMAIN>.` |
| `llm` | CNAME | `<DOMAIN>.` |

Why this shape rather than a dynamic A record per service:

- **A CNAME aliases the *name*, not a record type.** It inherits the apex's `A` *and* `AAAA` automatically, so dual-stack works with nothing extra. Per-subdomain records would mean ddclient maintaining `A`+`AAAA` × 4 names = **8 records**, growing by 2 per new service. This way it's **2, permanently.**
- Fewer records is fewer things that silently drift out of sync, and each new service needs no privileged config edit and no daemon reload — just one CNAME.
- The apex is a legal CNAME *target*. The rule that trips people up is that the apex can't **be** a CNAME (it must hold SOA/NS, and CNAME can't coexist with other records); pointing other names at it is fine.

A wildcard `*.<DOMAIN>` A record would mirror the wildcard certificate exactly, but most DDNS endpoints won't accept `*` as a hostname, and it would resolve every possible name to this host for no gain over a couple of CNAMEs. (Unclaimed names are dropped by the `:443` catch-all in `05-default.conf.template` regardless.)

Note `https://<DOMAIN>` (the bare apex) itself currently hits that `444` catch-all — the apex is an address anchor, not a served hostname. Give it a server block if you ever want it serving something.

The health check that matters is whether DNS agrees with reality:
```
curl -s https://api.ipify.org; echo            # IPv4
curl -s -6 https://api6.ipify.org; echo        # IPv6
dig +short <DOMAIN> A; dig +short <DOMAIN> AAAA
dig +short whisper.<DOMAIN>                    # should show the CNAME then the apex's addresses
```

### certbot
Certificates are obtained over the **DNS-01** challenge using Infomaniak's API, not the webroot/HTTP-01 flow this repo used to have. That switch is what makes a wildcard possible: Let's Encrypt will not issue `*.${DOMAIN}` over HTTP-01 at all.

Three things follow from it, and they're the real reasons to prefer it:

1. **No inbound port 80 dependency.** Let's Encrypt never contacts this machine. nginx plays no part in issuance or renewal, so you can issue a valid public certificate for a service that isn't publicly reachable at all — LAN-only, Tailscale-only, or bound to loopback.
2. **Your hostnames stop being published.** Every issued certificate is logged to public Certificate Transparency logs, and scanners mine those logs for fresh homelab hostnames. A per-subdomain cert announces `whisper.${DOMAIN}` to the world; a wildcard announces only `*.${DOMAIN}`.
3. **New subdomains are free.** No issuance step, no renewal config, no rate-limit exposure.

**Setup (once).** Create an API token at [manager.infomaniak.com](https://manager.infomaniak.com) → Users and profile → My profile → Developer → API tokens → Create token, with the **Domain** and **Domain write** scopes. Then:
```
cp nginx/certbot/infomaniak.ini.example nginx/certbot/infomaniak.ini
# paste the token into it
chmod 600 nginx/certbot/infomaniak.ini
```
> **This token is the most sensitive file in the repo.** A Domain-scoped token can rewrite *any* DNS record on the account, including MX — its blast radius is larger than the certificates it exists to obtain. It's gitignored; keep it at mode 600. If you want to shrink the exposure, CNAME `_acme-challenge.${DOMAIN}` to a throwaway zone so this token has no authority over your real records.

**Issue the certificate.** Do this *before* the first `docker compose up` — `nginx.conf` references the cert at `http` level, so nginx refuses to start without it:
```
scripts/certbot-issue.sh --dry-run   # always rehearse first
scripts/certbot-issue.sh
```
It requests `${DOMAIN}` and `*.${DOMAIN}` as **one certificate with two SANs** (not two certificates), under `--cert-name wildcard`, and waits ~120s for the TXT record to propagate. Use `--staging` if you need repeated attempts: failed *production* issuances count against a rate limit, staging ones don't.

There is no `certbot/certbot` image with the Infomaniak plugin (unlike `certbot/dns-cloudflare`), so [nginx/certbot/Dockerfile](nginx/certbot/Dockerfile) adds it in two lines. Both scripts build it automatically.

**Renewal.** `scripts/certbot-renew.sh` renews anything within 30 days of expiry and reloads nginx only if something actually changed.

The thing to understand here: **`certbot renew` is not per-certificate.** It walks every file in `/etc/letsencrypt/renewal/` and renews the ones that are due, each using the authenticator recorded in *its own* renewal config. So one job covers all certificates no matter how many you have, and old HTTP-01 certs and new DNS-01 certs renew correctly in the same run — which is what makes an incremental migration safe.

That's also why the script passes **no authenticator flags**. The old version passed `--webroot -w /var/www/certbot`, which *overrides* the stored authenticator for every cert in the run; leave that in and the wildcard would be forced onto HTTP-01 and fail. Keep the command bare.

**Scheduling it: [scripts/com.certbot.docker.renew.plist](scripts/com.certbot.docker.renew.plist).** This is the launchd job that actually runs the renewal — the macOS equivalent of a cron entry, and the piece that makes renewal automatic rather than something you remember to do. It isn't used from the repo directly; it's a template you install:
```
cp scripts/com.certbot.docker.renew.plist ~/Library/LaunchAgents/
# edit the copy: replace <path-to-script> with the absolute path to scripts/certbot-renew.sh
launchctl load ~/Library/LaunchAgents/com.certbot.docker.renew.plist
```
**Check that it actually runs.** The second column of `launchctl list` is the job's last exit status, and it is the only place a broken job shows up:
```
launchctl list | grep certbot     # want 0; 127 means "command not found"
```
This bit me for real: the installed copy pointed at `<user home>/scripts/certbot-renew.sh`, a path that doesn't exist, so the job had been exiting **127 on every run** — automatic renewal was silently dead and the old certificates were only surviving on manual runs. An absolute path that's right at install time is not right forever; check the exit status after any move or rename.

Three details in it are load-bearing:
- `StartInterval 43200` — fires every 12h. Frequent runs are near-free because certbot exits immediately when nothing is within 30 days of expiry, and the redundancy means a couple of missed or failed runs still leave weeks of slack.
- `EnvironmentVariables > PATH` — launchd jobs get a minimal PATH that does **not** include `/usr/local/bin` or `/opt/homebrew/bin`, so `docker` wouldn't be found. This is the usual reason a launchd job that works by hand fails on a schedule.
- `StandardOutPath` / `StandardErrorPath` → `/tmp/certbot-renew.{out,err}` — DNS-01 renewal can fail with *no visible symptom for up to 90 days* (a revoked API token, an API change), unlike the old webroot flow where a broken nginx was obvious immediately. These logs, plus `nginx/certbot/logs/letsencrypt.log`, are the only place it surfaces. Worth checking occasionally:
  ```
  tail -n 50 /tmp/certbot-renew.err
  docker exec nginx openssl x509 -enddate -noout -in /etc/letsencrypt/live/wildcard/fullchain.pem
  ```

**Reloading nginx after renewal** is done by the renew script on the host, not by a certbot deploy hook. There used to be a hook at `nginx/certbot/conf/renewal-hooks/deploy/reload-nginx.sh` running `docker exec nginx nginx -s reload` — but certbot runs deploy hooks *inside the certbot container*, which has no docker binary and no docker socket mounted, so it failed silently on every renewal and nginx kept serving the certificate it had loaded at startup. It's been deleted. The hook now just touches a sentinel file in the shared volume; the host script sees it and does the reload where a docker client actually exists.

### The initial http-only trick (no longer needed)
Kept as a note because the problem is instructive. With HTTP-01, first issuance was a chicken-and-egg: nginx wouldn't start because `ssl_certificate` pointed at a file that didn't exist, but the certificate needed nginx running to serve the challenge. The workaround was a temporary cert-free `nginx/templates.httponly/` config to bootstrap with.

DNS-01 removes the cycle entirely — certbot proves control through DNS without nginx running — so `templates.httponly/` and `conf.d.httponly/` have been deleted. The ordering requirement that replaces it is simply: **issue the certificate before starting nginx.**

### Exposing the Whisper transcription API safely
A Whisper speech-to-text server runs on the **host** (like ollama and ComfyUI), on the port set by `WHISPER_SERVER_PORT`. It offers an OpenAI-style `POST /v1/audio/transcriptions` endpoint **with no auth of its own**, so exposing it raw would let anyone on the internet burn your compute, DoS you, or upload huge files. nginx adds the entire security layer on top of it.

It's exposed on **its own subdomain**, at the root path (the wildcard cert already covers it, so this needed only a DNS record):
```
https://whisper.<DOMAIN>/v1/audio/transcriptions
```
> **Breaking change:** this used to be path-based at `https://<domain>/whisper/v1/audio/transcriptions`. Any client configured against the old URL — notably the Obsidian whisper plugin — must be updated.

The reverse-proxy config lives in two files:
- [nginx/templates/00-whisper.conf.template](nginx/templates/00-whisper.conf.template) — the http-context bits: the bearer-token `map`, the per-IP rate-limit zone, and the access-log format. These can't live inside a `server` block, which is why they stay in their own file even though whisper now has a server file too. **The `00-` prefix is load-bearing:** `include conf.d/*.conf` loads files alphabetically, and the `log_format` here must be parsed before the `access_log` that references it in `11-whisper.conf` — the prefix forces this file first. Renaming it (without moving `log_format` earlier) makes nginx fail to boot with `unknown log format whisper`. (The `map`/`limit_req_zone` tolerate forward references, so only `log_format` actually needs the ordering.)
- [nginx/templates/11-whisper.conf.template](nginx/templates/11-whisper.conf.template) — the `whisper.${DOMAIN}` server block and its `location /`.

What the location enforces, in request order:
1. **TLS** — the wildcard cert inherited from `nginx.conf`; nothing cert-related in this file.
2. **Bearer token** — requests whose `Authorization: Bearer <token>` isn't a known token get `401` before nginx ever touches Whisper. Clients send it exactly like the OpenAI SDK does. Tokens are defined in the `map` (see [multi-token access](#granting-access-to-other-people-multiple-tokens) below).
3. **Method lock** — only `POST`; anything else gets `405`.
4. **Rate limit** — 10 req/min, burst 5. Keyed on `$binary_remote_addr`, but see the caveat below: it behaves as a *global* cap, not a per-client one.
5. **Body cap** — 50M on this location (overrides the 100M default; OpenAI's own cap is 25MB).
6. **No path rewriting** — now that whisper owns its own hostname the URI passes through untouched, so `proxy_pass` has **no trailing slash** (`...:${WHISPER_SERVER_PORT}`). The old path-based version needed one to strip the `/whisper/` prefix; adding it back here would rewrite every request to `/`. Whisper is reached over `host.docker.internal`, which required adding `extra_hosts: host.docker.internal:host-gateway` to the nginx service in docker-compose (it wasn't there before, unlike open-webui/openclaw).

Each accepted request is written to `/var/log/nginx/whisper.log` with `user=<name>` (from the map, see below), so you can see who called: `docker exec nginx cat /var/log/nginx/whisper.log`.

Config wiring (secrets stay out of git via `.env`, injected through docker-compose into the templates via envsubst):
- `.env`: `WHISPER_SERVER_PORT=8901` and `WHISPER_AUTH_TOKEN=...` (generate with `openssl rand -hex 32`)
- `docker-compose.yml`: both passed into the nginx container's `environment`

**Gotcha — `could not build map_hash`:** the bearer-token `map` key is the whole string `Bearer <token>`. With a 64-char token (`openssl rand -hex 32`) that's ~71 bytes, longer than nginx's default 64-byte `map_hash_bucket_size`, so nginx refuses to boot. That's not about the token length being wrong — it's a hash-table slot size. Fixed with `map_hash_bucket_size 128;` in the `http {}` block of [nginx/nginx.conf](nginx/nginx.conf) — it's http-global and shared by the whisper and ollama token maps, and it has to be parsed before any `map` block (nginx reads it while building the map's hash), which is why it lives in the root config, ahead of the `include`, rather than in a per-service template.

Remember template edits need a recreate, not a reload (see the templates note above):
```
docker compose up -d --force-recreate nginx
docker exec nginx nginx -t
```
Test it (first succeeds, second is `401`, third is `405`):
```
curl -X POST https://whisper.<DOMAIN>/v1/audio/transcriptions \
  -H "Authorization: Bearer <token>" -F file=@sample.wav -F model=whisper-1
curl -X POST https://whisper.<DOMAIN>/v1/audio/transcriptions -F file=@sample.wav
curl https://whisper.<DOMAIN>/v1/audio/transcriptions -H "Authorization: Bearer <token>"
```
One caveat: nginx only secures the *internet-facing* path. Whisper itself still listens on the host, so make sure your host firewall doesn't also expose `WHISPER_SERVER_PORT` directly (or bind Whisper to `127.0.0.1`), otherwise the auth gets bypassed.

#### Granting access to other people (multiple tokens)
The bearer-token check is an nginx `map` in [nginx/templates/00-whisper.conf.template](nginx/templates/00-whisper.conf.template) that maps each valid `Bearer <token>` string to a **person's name**, defaulting to an empty string (= unauthorized). The `location` rejects the request when `$whisper_user` is empty. Mapping to a name rather than a plain yes/no gives you two things: the access log records *who* called, and you can revoke one person without disturbing the others.

To add a person:
1. Generate them a token: `openssl rand -hex 32`.
2. Add it as its own env var in `.env`, e.g. `WHISPER_AUTH_TOKEN_ALICE=...`.
3. Pass that var into the nginx container: uncomment the matching line under nginx's `environment` in `docker-compose.yml`.
4. Uncomment (and rename) the matching line in the `map` in `00-whisper.conf.template`:
   ```nginx
   "Bearer ${WHISPER_AUTH_TOKEN_ALICE}"    "alice";
   ```
5. Recreate nginx: `docker compose up -d --force-recreate nginx`.

To **revoke** someone, delete their `map` line (and their env var) and recreate. Two things to keep in mind: every *uncommented* `map` line must reference a real env var, or envsubst leaves the literal `${...}` in the config; and each token still has to fit `map_hash_bucket_size` (already bumped to 128, so full-length tokens are fine).

This is deliberately coarse-grained sharing, not real user management: there's no token expiry, no scopes, and the rate limit isn't per-token. For a handful of trusted people it's plenty; if you outgrow it, put an auth proxy (e.g. oauth2-proxy) or Whisper-side auth in front instead.

#### Caveat: the rate limit is global, not per-client
`limit_req_zone $binary_remote_addr` looks per-IP, but on Docker Desktop it isn't. Docker's proxy NATs all inbound traffic, so `$remote_addr` is **always** the gateway `192.168.65.1`, never the real caller. Verify it yourself:
```
docker exec nginx tail /var/log/nginx/whisper.log   # one source address for everything
```
Every client therefore shares one bucket. Two legitimate users contend for the same 10r/m, and a single abuser drains the whole budget instead of being throttled individually. Read it as a **total load cap protecting the host**, not as per-client fairness — the bearer token is the real access control, and the `user=` field in the log still tells you who called (it comes from the token map, not the address).

There's no clean fix on this platform: Docker Desktop for Mac has no host networking, and there's no upstream proxy adding `X-Forwarded-For` for `real_ip_from`/`set_real_ip_from` to trust. Putting Cloudflare (or any real proxy) in front would restore real client IPs — at the cost of terminating TLS somewhere else.

The same caveat applies to the ollama zone.

#### Feeding Whisper to OpenClaw (speech-to-text in chat + Telegram)
OpenClaw can transcribe inbound voice notes and audio clips by pointing its media pipeline at the Whisper API above. Once wired, a Telegram voice note (OGG/Opus) — or any attached audio on the HTTP chat endpoint — is transcribed *before* the agent reads it: the transcript becomes the message body, and with echo on the bot first replies `📝 "<transcript>"` so you can see what it heard. It's channel-agnostic, so the same config covers Telegram and every other channel.

The wiring lives in [.openclaw/openclaw.json](.openclaw/openclaw.json) under `tools.media.audio`, plus a few supporting pieces. The non-obvious parts:

- **It rides on the `openai` provider, by design.** OpenClaw's STT-capable providers each have a fixed request shape; only the `openai` one POSTs to the standard OpenAI `/v1/audio/transcriptions` endpoint that our Whisper server speaks (xAI uses `/stt`, OpenRouter/DeepInfra use different bodies). So `models` is `[{ "provider": "openai", "model": "whisper-1" }]` — `whisper-1` is just a placeholder the server ignores. Note the entry is an **object**, not a `"provider/model"` string (a string fails schema validation with `tools.media.audio.models.0: Invalid input`).
- **`plugins.allow` is a real allowlist.** Stock plugins are disabled unless listed (`openclaw plugins list` shows `N/95 enabled`). The `openai` plugin registers the audio transcriber, so `"openai"` must be in `plugins.allow` *and* enabled in `plugins.entries`, or STT silently has no provider.
- **The Whisper credential is decoupled from the provider key.** `baseUrl` (`https://whisper.${DOMAIN}/v1`) and the bearer token both live inside `tools.media.audio` — the token via `request.auth` (`mode: authorization-bearer`), which overrides the `Authorization` header at request time. So `models.providers.openai.apiKey` is **not** used for transcription; it only exists to satisfy OpenClaw's "a provider must have a non-empty key" gate. It's set to `${OPENAI_API_KEY}`, a placeholder in `.env` — drop a real `sk-...` key there later to use `openai` for chat, and STT is unaffected (its base URL + auth are independent). This is also why the audio path doesn't touch `models.providers.openai.baseUrl`: chat would still go to `api.openai.com`.
- **No `language` set, on purpose.** `tools.media.audio.language` is a hint forwarded to Whisper; pinning it (e.g. `en`) biases the decoder and mangles other languages. Leaving it unset makes Whisper auto-detect per clip, which handles mixed English/Spanish/Dutch.
- **Why the public URL, not the host directly.** OpenClaw's media fetch has an SSRF guard that blocks private networks by default (same story as the ComfyUI base URL). Using `https://whisper.${DOMAIN}/v1` sidesteps it entirely and reuses the bearer + TLS + rate-limit layer nginx already provides. Trade-offs: audio round-trips out through nginx and back, and STT shares Whisper's global 10 req/min cap.

Supporting wiring:
- `.env` (and `.env.example`): `OPENAI_API_KEY` placeholder — see the comment there.
- `docker-compose.yml`: `DOMAIN`, `WHISPER_AUTH_TOKEN`, and `OPENAI_API_KEY` are passed into the **openclaw** container's `environment` so the `${...}` refs in `openclaw.json` resolve (they were previously only wired into nginx).

Apply changes with a recreate (new env vars need more than a restart), then verify:
```
docker compose up -d --force-recreate openclaw
docker exec openclaw node dist/index.js config validate        # "Config valid"
docker exec openclaw node dist/index.js plugins list | grep -i openai   # "enabled"
```
Then send the bot a voice note and watch `docker logs -f openclaw | grep -iE 'media|transcri|audio'`. OGG/Opus (Telegram's format) transcribes fine as long as the Whisper server has ffmpeg.

### Exposing the Ollama API safely
Same recipe as whisper, applied to ollama — with two ollama-specific twists. Config lives in [nginx/templates/01-ollama.conf.template](nginx/templates/01-ollama.conf.template) (its own `map` → `$ollama_user`, rate-limit zone, and `log_format`) plus the server block in [nginx/templates/12-llm.conf.template](nginx/templates/12-llm.conf.template). Exposed on its own subdomain at the root path:
```
https://llm.<DOMAIN>/       e.g. POST /api/chat, /v1/chat/completions
```
> **Breaking change:** this used to be `https://<domain>/ollama/api/...`. Update any client pointed at the old path.
It reuses the whole whisper security model (per-person bearer tokens → `$ollama_user`, rate limiting with [the same global-not-per-IP caveat](#caveat-the-rate-limit-is-global-not-per-client), per-user access log at `/var/log/nginx/ollama.log`, TLS). The token/multi-token workflow is identical — swap `WHISPER_` for `OLLAMA_` and see [the multi-token section above](#granting-access-to-other-people-multiple-tokens). Two differences from whisper are worth understanding:

**1. Ollama binds to `127.0.0.1` — and that's deliberately left alone.** Ollama listens on `127.0.0.1:11434` (loopback only). You might expect that exposing it means setting `OLLAMA_HOST=0.0.0.0` — **don't.** The containers (open-webui, openclaw, hindsight) already reach it via `host.docker.internal`, which Docker Desktop forwards to the host loopback, and nginx reaches it the same way. Keeping it on loopback means nginx (with its token) is the *only* public door and the raw `11434` port is never exposed on a public interface. This also means exposing ollama through nginx is purely additive: the internal containers keep their existing direct `host.docker.internal:11434` path, untouched — they don't go through nginx or need a token.

**2. Inference-only: model-management endpoints are blocked.** Unlike whisper's single endpoint, ollama's API includes destructive/management routes (`/api/pull`, `/api/delete`, `/api/create`, `/api/push`, `/api/copy`, `/api/blobs`). A bearer token gates the front door, but to stop a *leaked* token from wiping or bloating your model library, the `location` returns `403` for those paths even with a valid token — inference and read endpoints (`/api/chat`, `/api/generate`, `/api/embed`, `/api/tags`, `/api/show`, `/v1/*`) pass through.

  Note the guard is a regex on `$uri`, and moving to a subdomain changed what `$uri` looks like: it's `^/api/(pull|push|...)` now, not `^/ollama/api/(...)`. If you ever reintroduce a path prefix, that regex has to change with it — otherwise it silently stops matching and model management becomes reachable with any valid token. A `403` on `POST /api/pull` is the test worth keeping (it's in the block below).

**Gotcha — ollama returns `403` for everything:** ollama validates the `Host` header (DNS-rebinding protection) and rejects any non-local value. Since nginx would otherwise forward `Host: <your public domain>`, every proxied request comes back `403`. The location fixes this by overriding `proxy_set_header Host "127.0.0.1:11434";` so ollama trusts the request. (Whisper doesn't do this — it doesn't check `Host`.) Also note `proxy_buffering off;` in the location, so streamed tokens flush to the client instead of being buffered.

Test it:
```
# inference — 200:
curl -sk https://llm.<DOMAIN>/api/version -H "Authorization: Bearer <token>"
curl -sk https://llm.<DOMAIN>/api/generate -H "Authorization: Bearer <token>" \
  -d '{"model":"<model>","prompt":"say hi"}'
# chat completions - 200:
curl -sk https://llm.<DOMAIN>/v1/chat/completions -H "Authorization: Bearer <token>" \
  -d '{"model":"huihui_ai/Qwen3.6-abliterated:35b","messages":[{"role": "system", "content": "be helpful"}, {"role": "user", "content": "tell me a joke"}]}'
# no/bad token — 401; management endpoint even with a valid token — 403:
curl -sk https://llm.<DOMAIN>/api/version
curl -sk -X POST https://llm.<DOMAIN>/api/pull -H "Authorization: Bearer <token>"
# unclaimed subdomain — connection dropped by the :443 catch-all, not Open WebUI:
curl -sk https://nope.<DOMAIN>/
```

#### CORS: what it's for and why the `OPTIONS` handling exists
Both the ollama and whisper locations answer `OPTIONS` requests with `204` + `Access-Control-Allow-*` headers *before* the token check. Here's why.

CORS (Cross-Origin Resource Sharing) is a **browser** security mechanism. When JavaScript running on origin A (e.g. a web app, or an Electron app like Obsidian) calls an API on a different origin B, the browser won't let the script send the request — or read the response — unless server B explicitly opts in with `Access-Control-Allow-Origin` headers. For any "non-simple" request (which includes anything carrying an `Authorization: Bearer` header), the browser first sends a **preflight** `OPTIONS` request to B to ask "am I allowed?", and crucially sends it **without** the `Authorization` header. Only if that preflight returns success + the right CORS headers does it send the real request.

That preflight is exactly what broke the Obsidian whisper plugin: the unauthenticated `OPTIONS` hit our token check and got `401`, so the browser aborted with a generic "network error" — even though the credentials were fine. `curl` and other non-browser clients never do this dance, which is why they worked. The fix is to short-circuit `OPTIONS` with a `204` + CORS headers ahead of auth, and to add `Access-Control-Allow-Origin` to the real responses so the browser lets the client read them.

Note this **doesn't weaken security**: CORS was never protecting this API — the bearer token is. CORS only governs which *browser origins* may talk to it, and a stolen token works from `curl` regardless of origin. That's why `Access-Control-Allow-Origin: *` is fine here (and effectively required, since a browser/Electron origin like `app://obsidian.md` is unpredictable). It works with `*` specifically because the token travels in an `Authorization` header, not a cookie — `*` would be rejected by browsers only if the request used `credentials: 'include'` (cookies).

**Gotcha — duplicate CORS headers:** both the whisper server and ollama *also* emit their own `Access-Control-Allow-Origin` on responses. Left alone, the proxied response then carries **two** `Access-Control-Allow-Origin` headers, which browsers reject outright (the spec allows exactly one) — so the request 200s at nginx but the browser still blocks it and the client shows a "network error". The locations therefore `proxy_hide_header` the upstream CORS headers and set a single clean one. If you ever see a browser-only failure on a request that clearly succeeded server-side, check for duplicated `Access-Control-*` headers first.

## Open WebUI
Interface managing multi tenancy, login, chat history and agentic tooling

### A note on open webui configuration env vars

Open webui settings are sql db first. You could setup add OLLAMA_BASE_URL=http://host.docker.internal:11434 or OPENAI_API_BASE_URL=http://openclaw:18789/v1 to the container environment variables but if you setup up a connection to a different llm in the ui, that will get saved in the litesql db and will take precedence over env vars. The db has user specific settings you don't want to commit, so commiting the db is not a good approach. Therefore, whatever changes you do in the ui will not be part of the containerized application and will have to be changed there in place. Environment variables are given prefence where pragmatic, [here's a list of supported variables](https://docs.openwebui.com/reference/env-configuration/).
By default, open webui sql database settings take precedence over env vars. To change this, the ENABLE_PERSISTENT_CONFIG variable is set to False in docker compose. That makes env vars take precedence.

### What doesn't go in env vars

#### connect to openclaw as llm backend
admin panel -> settings -> connections
Manage OpenAI API connections, add
URL: http://openclaw:18789/v1
Auth: Bearer (put your openclaw auth token)
API Type: Chat Completions


#### per model tool usage
You can enable tools such as open webui memories globally, with ENABLE_MEMORIES=True, you can also give users permission to activate the setting with USER_PERMISSIONS_FEATURES_MEMORIES=True and you can also force the setting to be enabled for all users by default with FEATURES_MEMORIES=True, but if you want a specific (tool usage native) model to use the memory tools, you have go to that model in the admin panel, advanced params and set function calling to Native.

#### per model web search
This is also something to be set on the models menu in the admin panel. Each model needs its own checkbox for web search to be ticked. A system prompt can also be set on that screen to guide model to use web search, for instance:
````
You are equipped with user memory tools. Use them to reference past facts or save new preferences when the user shares them.
````

#### Per model personality
In the models menu in the admin panel, you can put a system prompt telling the bot all you want him to be.

### generate_image
Has to be configured via ui. Follow [this guide](https://docs.openwebui.com/features/chat-conversations/image-generation-and-editing/comfyui/)
You have to configure image, by exporting your comfy ui workflow. Find an example at [comfyui/workflows/prompt2image_zimageturbo_api.json](comfyui/workflows/prompt2image_zimageturbo_api.json).
I put the following settings, following the example comfyui workflow from above:
| Setting | Value | Notes |
| --- | --- | --- |
| image generation | on | |
| model | z_image_turbo_bf16.safetensors | |
| image size | 1024x1024 | |
| steps | 8 | |
| image prompt generation | on | to use an llm for prompt refinement |
| image generation engine | comfyui | |
| comfyui base url | http://host.docker.internal:8188 | it runs locally on host. Click on refresh icon next to it to verify connection. If it works well you should see the job run history at http://localhost:8188/history and reach an example generated image at http://localhost:8188/view?filename=&lt;name&gt;.png&type=output |
| comfyui workflow | upload the api workflow file | |
| text | 57:27 | format is subgraph:node_id. If multiple nodes use that value, use comma separated list |
| unet_name | 57:28 | had to rename the field, by default was called checkpoint_name |
| width | 57:13 | |
| height | 57:13 | |
| steps | 57:3 | |
| seed | 57:3 | |

For image to image (a.k.a. image edit) these are the settings, referencing [comfyui/api/qwen_edit_uncensored_image2image.json](comfyui/api/qwen_edit_uncensored_image2image_api.json)
| Setting | Value | Notes |
| --- | --- | --- |
| image generation | on | |
| model | Qwen-Rapid-AIO-v2.safetensors | |
| image size | 1080x1920 | |
| image edit engine | comfyui | |
| ComfyUI Base URL | http://host.docker.internal:8188 | it runs locally on host. Click on refresh icon next to it to verify connection. If it works well you should see the job run history at http://localhost:8188/history and reach an example generated image at http://localhost:8188/view?filename=&lt;name&gt;.png&type=output |
| comfyui workflow | upload the api workflow file | Watch out while exporting the flow: the precense of the anywhere node led to comfyUI not exporting, without reporting any error, just silently ignoring the export. I replaced it by direct node connections and then export api worked|
| image | 123 | format is subgraph:node_id. If multiple nodes use that value, use comma separated list |
| prompt | 132 | had to rename the field, by default was called checkpoint_name |
| unet_name | 125 | |
| width | 148 | |
| height | 148 | |


#### Bug: Nonetype has no attribue lower
Model was generating images, visible in comfyui, but fetching them to open webui was failing with error:
{
  "error": "400: [ERROR: 'NoneType' object has no attribute 'lower']"
}
This is due to a bug on open webui 0.9.5 where urls for downloading generated images are validated to protect against Server Side Request Forgery. In general, a good idea, since it protects your computer's internal url's from being accessed by external users through the llm via tool calling. But for image search it makes no sense since the tool is safe. That validation only happens if this variable is set to False (default) so this is to turn it off, otherwise generate image tool won't be able to download the generated image. Looking at the error source in /app/backend/open_webui/retrieval/web/utils.py:validate_url(), workaround is by setting the ENABLE_RAG_LOCAL_WEB_FETCH env var to true

## Openclaw
Used separately from open webui, different use case, just bundled together. Openclaw is essencialy single-tenant, due to its memory mechanism.
Openclaw can be fully configured in the provided openclaw.json file, that should be mounted on the container.

### Manage secrets in openclaw.json
openclaw.json allows for env var substitution. You can add a secret to your local .env, then inject it in docker-compose.yml under openclaw's environment section, and finally call it in openclaw.json.
For instance, I created TELEGRAM_USER_ID to store the value of my telegram user id, then the TELEGRAM_OWNER variable is defined as telegram:${OPENCLAW_TELEGRAM_USER_ID}, so it can be inyected in openclaw.json inside the "ownerAllowFrom" list

### Connect to local ollama
Manage Ollama API connections, add
URL: http://host.docker.internal:11434
Auth: None

### ComfyUI image generation (and the SSRF "Blocked hostname" gotcha)
ComfyUI runs on the host, so openclaw (in a container) has to reach it across the container/host boundary. The comfy plugin is configured under `plugins.entries.comfy.config` in openclaw.json with a `baseUrl` and `mode: local`.

The catch: openclaw guards outbound fetches against SSRF (Server Side Request Forgery). When it hits ComfyUI you'll see this in the logs and image generation fails:
```
[security] blocked URL fetch (comfy-image-generate) targetOrigin=http://host.docker.internal:8188 reason=Blocked hostname or private/internal/special-use IP address
[image-generation] candidate failed: comfy/workflow: Blocked hostname or private/internal/special-use IP address
```
Setting `mode: local` is supposed to allow reaching a private-network host (it sets `allowPrivateNetwork`), but there's a subtlety: openclaw only actually lifts the block when the `baseUrl` host is a **literal private/loopback IP** (like `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `127.x.x.x`). A **hostname** such as `host.docker.internal` does not pass that check, so it stays blocked even though it resolves to a private IP. (This is why `host.docker.internal` still works fine for ollama above but not for comfy — ollama's provider isn't behind the same SSRF fetch guard.)

Fix: point comfy's `baseUrl` at the host's literal gateway IP instead of the hostname. This repo wires it through an env var so it stays out of git and is easy to change per platform:
- `.env`: `OPENCLAW_COMFY_BASE_URL=http://192.168.65.254:8188`
- `docker-compose.yml`: pass it into the container under openclaw's `environment` (`OPENCLAW_COMFY_BASE_URL: ${OPENCLAW_COMFY_BASE_URL}`)
- `openclaw.json`: `"baseUrl": "${OPENCLAW_COMFY_BASE_URL}"`

**On macOS (Docker Desktop):** use `192.168.65.254`, Docker Desktop's fixed host-gateway IP.

**On Linux:** that IP won't exist. The container reaches the host over the docker bridge gateway, usually `172.17.0.1` (default `docker0` bridge) — so use `http://172.17.0.1:8188`. Confirm the exact value with:
```
# from the host
docker exec openclaw getent hosts host.docker.internal
# or inspect /etc/hosts inside the container for the host.docker.internal IPv4 entry
docker exec openclaw cat /etc/hosts
```
Whatever IPv4 `host.docker.internal` maps to there is what to put in `OPENCLAW_COMFY_BASE_URL`. Also make sure ComfyUI is actually listening on that interface (start it with `--listen 0.0.0.0`), and that the host firewall allows the container subnet to reach port 8188.

After changing the env var, recreate the container so it picks it up:
```
docker compose up -d --force-recreate openclaw
```

### Hide openclaw models from users
You can't group them all under openclaw. Whether a model comes from ollama directly or openclaw, it's still just one model in the list. Permissions per model should be managed separately, using RBAC, so you can manually mark each openclaw model as private, only for some users and the rest as public or assign access to a group

### forward request headers to downstream llm
add env var:
ENABLE_FORWARD_USER_INFO_HEADERS=true

## Hindsight
Advanced episodic memory engine, with knowledge graph. This service provides a memory bank that can be set to different levels of granularity, even per user, per input channel. The knowledge graph and time tags in the memories allow for advanced reasoning. It supports openclaw natively and comes with its own ui

# Secret management
put your secrets in a local .env file on the project root. An .env.example file is provided as guide. Whatever you put in there will be inyected on docker compose

# ComfyUI
Not part of this repo, but openclaw calls it for image generation/editing. Expected to run on port `8188` (see the SSRF note above for reaching it from the container).

Images live in ComfyUI's own dirs, relative to its install path: uploads/inputs in `input/`, results in `output/`.

Two workflow files, nearly identical:
- [comfyui/api/qwen_edit_uncensored_image2image_api.json](comfyui/api/qwen_edit_uncensored_image2image_api.json) — image edit only.
- [comfyui/api/qwen_edit_uncensored_image2image_prompt2image_api.json](comfyui/api/qwen_edit_uncensored_image2image_prompt2image_api.json) — same graph, but its `LoadImage` node defaults to `blank.png`, so it also does text-to-image when no image is attached (one workflow for both generate and edit).

The only diff is that default image. For the hybrid to work, copy [misc/blank.png](misc/blank.png) into ComfyUI's `input/` folder.

## Exposing ComfyUI remotely (Tailscale, tailnet-only)

ComfyUI is reachable from outside the house over **Tailscale**, *not* through the nginx bearer-token recipe used for whisper/ollama. That's a deliberate choice, for two reasons:

1. **ComfyUI has no auth and is an RCE surface.** It executes arbitrary Python via custom nodes and reads/writes host files, so a public door — even a bearer-gated one — is one misconfig away from full host compromise. Tailscale removes it from the public internet entirely: only enrolled devices on the tainet can open a connection at all. Network-level control instead of app-level.
2. **It's a browser UI with websockets, not an API.** The bearer-token `map` works because SDK clients attach `Authorization` to every call; a browser loading a page + WebSocket can't. Over the tainet it Just Works with no token/CORS gymnastics.

**Binding.** ComfyUI (the Comfy Desktop app) already listens on `127.0.0.1:8188` — loopback only, no flag change needed. That single binding satisfies all three consumers without exposing anything on the LAN:
- **host tools** hit `127.0.0.1:8188` directly;
- **containers** (openclaw, open-webui) reach it via `host.docker.internal`, which Docker Desktop forwards to the host loopback — the exact mechanism ollama relies on;
- **anyone on the house LAN** cannot reach it (nothing is bound to the LAN interface).

Binding to `0.0.0.0` would expose it to the house; binding to the tainet IP (`100.x`) would break container access, because `host.docker.internal` maps to the host loopback, not the tainet interface. Loopback is the only interface all three can share — and Tailscale bridges the tainet to it.

**The bridge** is a persistent Tailscale Serve proxy (run once on the host; requires Serve + HTTPS/MagicDNS enabled once in the tainet admin console):

```
tailscale serve --bg 8188            # listen HTTPS/443 on the node's <name>.<tailnet>.ts.net, proxy -> 127.0.0.1:8188
tailscale serve status               # view config: "<name>.ts.net (tailnet only) | / proxy http://127.0.0.1:8188"
tailscale serve reset                # tear it down
```

- `--bg` makes it **persistent** (written to tailscaled state, survives reboots); without it, Serve runs in the foreground and is torn down on Ctrl-C.
- The `8188` is the **proxy target**, not the listen port. Serve's default listen mode is HTTPS on **443** of the `.ts.net` name, with an auto-provisioned Let's Encrypt cert — which is why the URL has no `:8188`.
- This is **Serve, not Funnel.** Serve = tainet-only. Funnel would republish it to the public internet, defeating the whole point — don't use it here.

**Why 443 doesn't clash with nginx.** nginx's 443 is a real kernel socket that Docker publishes on the LAN/public interfaces. Serve's 443 lives inside tailscaled's own userspace stack: remote tainet traffic arrives *inside the WireGuard tunnel* (UDP), gets decrypted, and tailscaled terminates the TLS with the `.ts.net` cert — all before the host kernel ever sees a SYN on 443. Same number, never the same packets:
- LAN/public `:443` → kernel → Docker → **nginx** (`chat.${DOMAIN}`, …)
- tainet `:443` → tunnel → **tailscaled** → **ComfyUI**

**Gotcha — you cannot test this from the serving Mac.** A connection originating *on the host* to its own tainet IP is local delivery, so the host kernel routes it to Docker's `[::]:443` listener (dual-stack, `net.inet6.ip6.v6only=0`, so it grabs IPv4 too) and you get nginx's `*.${DOMAIN}` cert instead of the `.ts.net` one — `curl` fails with "no alternative certificate subject name matches". This is *not* a real failure; it only affects host-originated connections. **Verify from another tainet device** (e.g. a phone with Wi-Fi off, forcing it through the tainet): open `https://<node>.<tailnet>.ts.net/` and confirm ComfyUI loads with a valid padlock.

Where the workflow JSON goes: for openclaw, copy it into the openclaw workflows folder (`.openclaw/workflows/`); for open-webui, upload it via the UI.