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