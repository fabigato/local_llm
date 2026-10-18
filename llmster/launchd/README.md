# Running LM Studio headless (launchd daemon)

LM Studio's headless daemon, **llmster**, serves an OpenAI-compatible API on
`http://127.0.0.1:1234/v1`. LM Studio itself is not part of this repo. It's
installed on the host under `~/.lmstudio` (`lms` CLI, llmster, models). What
lives here makes it start **at boot with nobody logged in**, start the server,
and load the default model. It's the same approach as
[comfyui/launchd](../../comfyui/launchd/README.md), and it also relies on
FileVault being off.

## Why the wrapper script

`lms daemon up` forks llmster and returns, so launchd can't supervise it. And
llmster doesn't remember across restarts that its server was started or which
models were loaded. [llmster-server.sh](llmster-server.sh) runs llmster in the
foreground, so `KeepAlive` works, then runs `lms server start` and `lms load`
against it each time. A failed load is logged but doesn't stop the server: JIT
loading still serves any downloaded model on demand.

## Files

| File | Installed to |
| --- | --- |
| [com.local.llmster.plist](com.local.llmster.plist) | `/Library/LaunchDaemons/com.local.llmster.plist` |
| [llmster-server.sh](llmster-server.sh) | `/usr/local/sbin/llmster-server.sh` |
| [llmster.newsyslog.conf](llmster.newsyslog.conf) | `/etc/newsyslog.d/llmster.conf` |

The model, port, context length and API identifier are variables at the top of
the script.

## Install

Everything is **copied** and root-owned, never symlinked, for the same reason
as ComfyUI: a user-writable file that launchd starts from the system domain is
a privilege escalation.

```sh
cd ~/repos/local_llm/llmster/launchd

# 1. Stop the llmster that `lms` auto-started in your session
~/.lmstudio/bin/lms daemon down

# 2. Install
sudo install -o root -g wheel -m 755 llmster-server.sh /usr/local/sbin/llmster-server.sh
sudo install -o root -g wheel -m 644 com.local.llmster.plist /Library/LaunchDaemons/com.local.llmster.plist
sudo install -o root -g wheel -m 644 llmster.newsyslog.conf /etc/newsyslog.d/llmster.conf
sudo touch /var/log/llmster-server.log /var/log/llmster-server.launchd.log
sudo chown fabigato:staff /var/log/llmster-server.log /var/log/llmster-server.launchd.log

# 3. Start
sudo launchctl bootstrap system /Library/LaunchDaemons/com.local.llmster.plist
```

## Operating it

```sh
sudo launchctl print system/com.local.llmster | grep -E 'state|pid|last exit'
tail -f /var/log/llmster-server.log          # wrapper: start, server, load
tail -f /var/log/llmster-server.launchd.log  # llmster's own console

lms ps                                       # what's loaded
curl -s 127.0.0.1:1234/v1/models

# Restart (reloads the model)
sudo launchctl kickstart -k system/com.local.llmster
# Stop
sudo launchctl bootout system/com.local.llmster
```

**Don't run `lms daemon down` or `lms daemon update` while the job is loaded.**
launchd sees llmster exit and restarts it within 30 s. To update, `bootout`
first, run `lms daemon update`, then `bootstrap` again. The script finds the new
llmster version on its own.

`lms` commands from your terminal (`ls`, `ps`, `get`, `load`, `unload`) talk to
the daemon's llmster as normal.

## Reasoning effort and the chat template patch

The model's own `chat_template.jinja` defaults `reasoning_effort` to `xhigh`,
and LM Studio can't pass a client's `reasoning_effort` through to it (the log
says `No valid custom reasoning fields found … Reasoning setting 'medium' cannot
be converted`). So every request ran at `xhigh` no matter what Hermes or
Open WebUI asked for. Combined with clients that sent no `max_tokens`, one story
prompt thought for 12.5 hours on 2026-10-16 until the client gave up.

The effort level is only a sentence the template puts at the top of the system
prompt (`xhigh`: think carefully…; `low`: keep thinking brief…; `medium`:
nothing). It steers; it doesn't cap. The hard stop is each client's
`max_tokens`, which counts thinking too.

[qwen3.8-chat-template.patch](../qwen3.8-chat-template.patch) changes the
default to `medium` and lets a standalone `/low` or `/xhigh` word in the last
user message pick the level, in any client. Re-apply it after re-downloading
the model:

```sh
cd ~/.lmstudio/models/KostkaIT/Qwen3.8-27B-Huihui-Abliterated-oQ6e-MTP-MLX
cp -p chat_template.jinja chat_template.jinja.orig
patch chat_template.jinja ~/repos/local_llm/llmster/qwen3.8-chat-template.patch
# the template is read at load time
lms unload qwen3.8-27b
lms load qwen3.8-27b-huihui-abliterated-oq6e-mtp-mlx --identifier qwen3.8-27b -c 262144 -y
```

Output caps per client: openclaw `maxTokens` in `.openclaw/openclaw.json`
(32768), Hindsight's `*_MAX_COMPLETION_TOKENS` in compose (32768), Hermes
`providers.lm-studio.extra_body.max_tokens` in `~/.hermes/config.yaml` (32768;
Hermes ignores `model.max_tokens`), Open WebUI's Max Tokens in the model's
Advanced Params (64554).
