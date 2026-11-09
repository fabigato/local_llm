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
#
# ---------------------------------------------------------------------------
# Decision 5: a watchdog keeps the pinned load right, not just at startup.
#
# On 2026-11-09 only the model worker crashed (`Prediction failed: Error:
# Channel Error`); llmster stayed up, so nothing re-ran the load below. Clients
# ask for the alias "qwen3.8-27b", which JIT can't resolve, so they got "No
# models loaded" for 2.5 h. Then a request naming the full model key JIT-loaded
# it with LM Studio's defaults (8192 context, 1 h TTL), and OpenClaw failed
# with "tokens to keep ... greater than the context length".
#
# Every WATCH_EVERY seconds the watchdog reloads the alias if it's missing, has
# the wrong context or has a TTL, and unloads any other copy of the same model
# key (a stray JIT load would hold another 22 GiB). Other models are left
# alone. A failed load backs off RETRY_AFTER. Touch PAUSE_FILE to unload the
# model by hand (e.g. to give ComfyUI the memory) without it coming back.
#
# ---------------------------------------------------------------------------
# Decision 6: idle KV is purged by reloading, not by a TTL.
#
# The KV cache is NOT released when a reply ends. Measured 2026-11-09: worker
# 24 GB idle, 38 GB during a 60k-token request, still 27 GB a minute after it.
# Each of the 4 slots keeps its last conversation, so forgotten full-context
# chats could pin ~64 GiB. LM Studio has no call to drop it short of unloading.
#
# A TTL would unload the weights too, and then the next alias request fails
# (see Decision 5). Instead, after PURGE_IDLE with no request, and only if the
# worker holds more than PURGE_SLACK over the weights, the watchdog unloads and
# immediately reloads: ~25 s of downtime when nobody is using it, weights stay.

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
# per conversation. Not freed when a reply ends: see Decision 6.
CONTEXT_LENGTH=262144

# Watchdog, see Decisions 5 and 6.
WATCH_EVERY=30                     # seconds between checks
PURGE_IDLE=3600                    # purge KV after this long with no request
PURGE_SLACK=$((2 * 1024 ** 3))     # ...if the worker holds this much over the weights
RETRY_AFTER=300                    # back-off after a failed load
PAUSE_FILE="$HOME/.lmstudio/watchdog.pause"   # touch it to stop the watchdog acting

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

load_model() {
	lms load "$MODEL_KEY" --identifier "$MODEL_IDENTIFIER" \
		--context-length $CONTEXT_LENGTH -y | while read -r l; do log "load: $l"; done
}

# One line: <state> <lastUsedTime ms> <sizeBytes> [stray identifiers...]
# state: ok | missing | wrong (context or TTL differs from the pinned load)
model_state() {
	"$LMS" ps --json 2>/dev/null | /usr/bin/python3 -I -c '
import json, sys
key, ident, ctx = sys.argv[1], sys.argv[2], int(sys.argv[3])
try: ps = json.load(sys.stdin)
except Exception: print("unknown 0 0"); sys.exit()
mine = [m for m in ps if m.get("identifier") == ident]
stray = [m["identifier"] for m in ps if m.get("modelKey") == key and m.get("identifier") != ident]
if not mine: st = "missing"
elif mine[0].get("contextLength") != ctx or mine[0].get("ttlMs"): st = "wrong"
elif mine[0].get("status") != "idle" or mine[0].get("queued"): st = "busy"
else: st = "ok"
m = mine[0] if mine else {}
print(st, m.get("lastUsedTime") or 0, m.get("sizeBytes") or 0, *stray)
' "$MODEL_KEY" "$MODEL_IDENTIFIER" $CONTEXT_LENGTH
}

# Largest phys_footprint among model workers, in bytes.
worker_bytes() {
	local pid max=0 b
	for pid in $(pgrep -f 'lib/llmworker.js'); do
		b=$(footprint -f bytes $pid 2>/dev/null | awk '/phys_footprint:/{print $2; exit}')
		(( ${b:-0} > max )) && max=$b
	done
	print $max
}

watchdog() {
	# next_*: back-offs, so an action that silently fails isn't retried every tick.
	local st used size stray next_try=0 next_stray=0 next_purge=0 now
	while sleep $WATCH_EVERY; do
		[[ -e $PAUSE_FILE ]] && continue
		read -r st used size stray <<<"$(model_state)"
		now=$(date +%s)

		if [[ -n $stray ]] && (( now >= next_stray )); then
			for s in ${=stray}; do
				log "watchdog: unloading stray copy '$s'"
				lms unload "$s" | while read -r l; do log "unload: $l"; done
			done
			next_stray=$((now + RETRY_AFTER))
		fi

		case $st in
		missing|wrong)
			(( now < next_try )) && continue
			log "watchdog: '$MODEL_IDENTIFIER' is $st, reloading"
			[[ $st == wrong ]] && lms unload "$MODEL_IDENTIFIER" | while read -r l; do log "unload: $l"; done
			load_model
			[[ $(model_state) == ok* ]] || { log "watchdog: reload failed, retry in ${RETRY_AFTER}s"; next_try=$((now + RETRY_AFTER)); }
			;;
		ok)
			(( now >= next_purge && used > 0 && now - used / 1000 >= PURGE_IDLE )) || continue
			local held=$(worker_bytes)
			(( held > size + PURGE_SLACK )) || continue
			log "watchdog: idle $(( (now - used / 1000) / 60 )) min, worker $((held / 1024 ** 2)) MiB vs weights $((size / 1024 ** 2)) MiB; reloading to free KV"
			next_purge=$((now + PURGE_IDLE))
			lms unload "$MODEL_IDENTIFIER" | while read -r l; do log "unload: $l"; done
			load_model
			;;
		esac
	done
}

load_model

watchdog &
WATCHDOG_PID=$!
trap 'log "SIGTERM, stopping llmster"; kill $WATCHDOG_PID 2>/dev/null; kill -TERM $LLMSTER_PID 2>/dev/null; wait $LLMSTER_PID; exit 0' TERM INT

wait $LLMSTER_PID
rc=$?
kill $WATCHDOG_PID 2>/dev/null
log "llmster exited with $rc"
exit $rc
