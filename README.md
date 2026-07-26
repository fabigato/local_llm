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

### Editing the nginx config (templates)
The active config isn't edited directly. The files under `nginx/templates/*.template` are rendered into `/etc/nginx/conf.d/*.conf` by the official nginx image's entrypoint, which runs `envsubst` (this is how `${PRIMARY_DOMAIN}` / `${SECONDARY_DOMAIN}` get substituted from the environment). Crucially, **this rendering happens only once, at container startup.**

That means `docker compose exec nginx nginx -s reload` is **not** enough after editing a template: reload only re-reads the already-rendered `.conf` files in `conf.d/`, it does not re-run `envsubst`. To pick up template changes you have to recreate (or restart) the container so the entrypoint renders them again:
```
docker compose up -d --force-recreate nginx
```
You can verify what actually landed in the live config with:
```
docker exec nginx cat /etc/nginx/conf.d/openwebui.conf
```
(Example gotcha: adding `client_max_body_size 100M;` to fix a 413 on uploads only takes effect after the recreate — a plain reload leaves the old 1MB default in place. This error was particularly obscure in open webui browser since it only complained about some non well formed json. This happened because nginx send an html error to open webui. To see what was going on you had to go to the broser's developer view on the network tab and reproduce the error, verifying the url was returning a 413 due to content size too large)

### certbot
The ssl certificate can be downloaded for the first time with this docker command:
````
docker run --rm \
  -v $(pwd)/nginx/certbot/conf:/etc/letsencrypt \
  -v $(pwd)/nginx/certbot/www:/var/www/certbot \
  certbot/certbot certonly \
  --webroot \
  -w /var/www/certbot \
  -d chat.example.com \
  --agree-tos \
  --no-eff-email \
  -m example@email.com \
  --non-interactive
````

To renew the certificate, the following script is provided:
```
scripts/certbot-renew.sh
````
Then you can create a cron job (or launchd on mac) to run it on a cadence. For instance daily, the certbot container won't actually renew the certificate unless is necessary.

To make sure nginx restarts upon certificate renewal, the script nginx/certbot/conf/renewal-hooks/deploy/reload-nginx.sh is provided as an nginx renewal hook, meaning it will be triggered when nginx reports a certificate renewal, and the script will simply restart the nginx docker container by name.

### The initial http only trick
nginx open webui config is such that http just forwards to https, so when you run the initial request to letsencrypt for a certificate, you get locked in a chicken egg problem, since you need to prove your control of the server to letsencrypt by putting their challenge in a location they can access. But if only https is serving external requests, nobody can access your https server to verify you placed the challenge file there. To this end, the nginx/templates.httponly/openwebui_httponly.conf.template is provided, to setup an initial, temporary http only server so you can download and place the challenge file. Then you can switch to the proper http -> https config.

### Exposing the Whisper transcription API safely
A Whisper speech-to-text server runs on the **host** (like ollama and ComfyUI), on the port set by `WHISPER_SERVER_PORT`. It offers an OpenAI-style `POST /v1/audio/transcriptions` endpoint **with no auth of its own**, so exposing it raw would let anyone on the internet burn your compute, DoS you, or upload huge files. nginx adds the entire security layer on top of it.

It's exposed **path-based** on both the primary and secondary domains (no new DNS record or certificate needed):
```
https://<PRIMARY_DOMAIN>/whisper/v1/audio/transcriptions
https://<SECONDARY_DOMAIN>/whisper/v1/audio/transcriptions
```
The reverse-proxy config lives in two files:
- [nginx/templates/00-whisper.conf.template](nginx/templates/00-whisper.conf.template) — the http-context bits: the bearer-token `map`, the per-IP rate-limit zone, and the access-log format. These are global, so they're defined once and shared by both domains. **The `00-` prefix is load-bearing:** `include conf.d/*.conf` loads files alphabetically, and the `log_format` here must be parsed before the `access_log` that references it in `openwebui.conf` — the prefix forces this file first. Renaming it (without moving `log_format` earlier) makes nginx fail to boot with `unknown log format whisper`. (The `map`/`limit_req_zone` tolerate forward references, so only `log_format` actually needs the ordering.)
- [nginx/templates/openwebui.conf.template](nginx/templates/openwebui.conf.template) — the actual `location /whisper/`, duplicated inside both the `${PRIMARY_DOMAIN}` and `${SECONDARY_DOMAIN}` `:443` server blocks. (nginx can't add a location to an existing `server_name` from a separate `server` block, so it can't live entirely in its own file — it's a second `location` in each server, next to open webui's `location /`.)

What the location enforces, in request order:
1. **TLS** — reuses the per-domain cert; no separate cert for this.
2. **Bearer token** — requests whose `Authorization: Bearer <token>` isn't a known token get `401` before nginx ever touches Whisper. Clients send it exactly like the OpenAI SDK does. Tokens are defined in the `map` (see [multi-token access](#granting-access-to-other-people-multiple-tokens) below).
3. **Method lock** — only `POST`; anything else gets `405`.
4. **Rate limit** — 10 req/min per IP, burst 5.
5. **Body cap** — 50M on this location (overrides the 100M default; OpenAI's own cap is 25MB).
6. **Prefix strip** — `proxy_pass ...:${WHISPER_SERVER_PORT}/` turns `/whisper/v1/audio/transcriptions` into `/v1/audio/transcriptions` for Whisper. Whisper is reached over `host.docker.internal`, which required adding `extra_hosts: host.docker.internal:host-gateway` to the nginx service in docker-compose (it wasn't there before, unlike open-webui/openclaw).

Each accepted request is written to `/var/log/nginx/whisper.log` with `user=<name>` (from the map, see below), so you can see who called: `docker exec nginx cat /var/log/nginx/whisper.log`.

Config wiring (secrets stay out of git via `.env`, injected through docker-compose into the templates via envsubst):
- `.env`: `WHISPER_SERVER_PORT=8901` and `WHISPER_AUTH_TOKEN=...` (generate with `openssl rand -hex 32`)
- `docker-compose.yml`: both passed into the nginx container's `environment`

**Gotcha — `could not build map_hash`:** the bearer-token `map` key is the whole string `Bearer <token>`. With a 64-char token (`openssl rand -hex 32`) that's ~71 bytes, longer than nginx's default 64-byte `map_hash_bucket_size`, so nginx refuses to boot. That's not about the token length being wrong — it's a hash-table slot size. Fixed with `map_hash_bucket_size 128;` in the whisper template, which lets you keep a full-length token.

Remember template edits need a recreate, not a reload (see the templates note above):
```
docker compose up -d --force-recreate nginx
docker exec nginx nginx -t
```
Test it (first succeeds, second is `401`, third is `405`):
```
curl -X POST https://<PRIMARY_DOMAIN>/whisper/v1/audio/transcriptions \
  -H "Authorization: Bearer <token>" -F file=@sample.wav -F model=whisper-1
curl -X POST https://<PRIMARY_DOMAIN>/whisper/v1/audio/transcriptions -F file=@sample.wav
curl https://<PRIMARY_DOMAIN>/whisper/v1/audio/transcriptions -H "Authorization: Bearer <token>"
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

This is deliberately coarse-grained sharing, not real user management: there's no token expiry, no scopes, and the rate limit is per-IP, not per-token. For a handful of trusted people it's plenty; if you outgrow it, put an auth proxy (e.g. oauth2-proxy) or Whisper-side auth in front instead.

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

Where the workflow JSON goes: for openclaw, copy it into the openclaw workflows folder (`.openclaw/workflows/`); for open-webui, upload it via the UI.