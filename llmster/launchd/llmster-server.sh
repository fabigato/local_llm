#!/bin/zsh
#
# llmster-server.sh — run LM Studio's headless daemon (llmster) at boot, start
# its OpenAI-compatible server and load the default model into it.
#
# Supervisor wrapper, same shape as nas/scripts/nas-jellyfin/jellyfin-server.sh:
# it starts llmster as a child, configures it through `lms`, then waits on it
# for as long as it lives. launchd (com.local.llmster) restarts the whole thing.
#
# ---------------------------------------------------------------------------
# Decision 1: a LaunchDaemon, not `lms daemon up` or a login item.
#
# This machine has no automatic login, so anything in the user session waits
# until someone is at the keyboard. `lms daemon up` forks llmster and returns,
# which launchd can't supervise; and llmster forgets its server state and its
# loaded models on every restart. Running it in the foreground here gets us
# KeepAlive, and the steps after it put the server and model back each time.
#
# Verified 2026-10-11: llmster run directly stays in the foreground, and `lms`
# talks to that instance rather than spawning a second one.
#
# ---------------------------------------------------------------------------
# Decision 2: the llmster path is read at runtime, not hard-coded.
#
# llmster lives in a versioned directory (~/.lmstudio/llmster/<ver>/) that
# `lms daemon update` replaces. It records the current one in
# llmster-install-location.json, so an update doesn't break boot.
#
# ---------------------------------------------------------------------------
# Decision 3: a failed model load doesn't take the server down.
#
# The server is still useful without the pinned model: JIT loading means a
# request naming any downloaded model loads it on demand. So a load failure
# (e.g. memory guardrails tripping because ComfyUI is holding a lot) is logged
# and the wrapper carries on waiting on llmster.
#
# ---------------------------------------------------------------------------
# Decision 4: the model, and why MTP is off.
#
# Huihui-abliterated Qwen3.8-27B in KostkaIT's oQ6e MLX quant (6-bit, sensitive
# tensors at 8-bit, 22 GiB resident). It needs MLX engine >= 1.13.1: on 1.11.0
# (mlx_lm 0.31.3) it loads fine and then emits pure garbage. If output turns to
# gibberish after a reinstall, check `lms runtime ls` before blaming the model.
#
# It keeps the native MTP head, but --speculative-draft-mtp measured no gain
# (20.6 vs 20.7 tok/s, 2026-10-11, M4 Max), so it isn't enabled.

set -u

export HOME=/Users/fabigato
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

LMS="$HOME/.lmstudio/bin/lms"
LOCATION_JSON="$HOME/.lmstudio/.internal/llmster-install-location.json"
LOG=/var/log/llmster-server.log

PORT=1234
BIND=127.0.0.1
MODEL_KEY="qwen3.8-27b-huihui-abliterated-oq6e-mtp-mlx"
MODEL_IDENTIFIER="qwen3.8-27b"
# The model's max. Only 16 of 64 layers keep a KV cache (the rest are linear
# attention), ~64 KiB/token, allocated as it fills: a full window is ~16 GiB
# per conversation in flight (up to 4 by default), nothing when idle.
CONTEXT_LENGTH=262144

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG" 2>/dev/null; }

# lms prints ANSI colour and cursor codes even when not on a tty, and `load`
# draws a progress spinner by redrawing "Loading ... N%" after each \r.
lms() {
	"$LMS" "$@" 2>&1 | tr '\r' '\n' | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -v -E '^Loading .*%|^[[:space:]]*$'
}

LLMSTER=$(plutil -extract path raw "$LOCATION_JSON" 2>/dev/null)
if [[ -z "$LLMSTER" || ! -x "$LLMSTER" ]]; then
	log "llmster not found via $LOCATION_JSON; exiting"
	exit 1
fi

log "starting $LLMSTER"
cd "${LLMSTER:h}" || exit 1
"$LLMSTER" &
LLMSTER_PID=$!

# launchd sends SIGTERM to the wrapper on shutdown/bootout; pass it on so
# llmster shuts down cleanly instead of being SIGKILLed after ExitTimeOut.
trap 'log "SIGTERM, stopping llmster"; kill -TERM $LLMSTER_PID 2>/dev/null; wait $LLMSTER_PID; exit 0' TERM INT

# Wait until it's our llmster that answers, not merely "something does".
for _ in {1..60}; do
	lms daemon status | grep -q "PID: $LLMSTER_PID" && break
	kill -0 $LLMSTER_PID 2>/dev/null || { log "llmster exited during startup"; exit 1; }
	sleep 2
done

lms server start --port $PORT --bind $BIND | while read -r l; do log "server: $l"; done

lms load "$MODEL_KEY" --identifier "$MODEL_IDENTIFIER" \
	--context-length $CONTEXT_LENGTH -y | while read -r l; do log "load: $l"; done

wait $LLMSTER_PID
rc=$?
log "llmster exited with $rc"
exit $rc
