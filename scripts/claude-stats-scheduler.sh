#!/bin/bash
# claude-stats-scheduler.sh
# Recalcule ~/.claude/stats-cache.json à chaque tick (1×/h via launchd).
# Recalcul complet : ~1-2s pour ~17k fichiers de session JSONL.
#
# LaunchAgent : ~/Library/LaunchAgents/com.claude.stats-scheduler.plist

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REFRESH_SCRIPT="$SCRIPT_DIR/refresh-claude-stats.mjs"
LOGFILE="/tmp/claude-stats-scheduler.log"
LOCKFILE="/tmp/claude-stats-scheduler.lock"

NODE="$(command -v node 2>/dev/null)"
if [ -z "$NODE" ]; then
    # Fallback : charger nvm (environnement launchd / cron sans PATH complet)
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    NODE="$(command -v node 2>/dev/null)"
fi

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

# ── Verrou anti-double-exécution ────────────────────────────────────
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        log "SKIP - Instance déjà en cours (PID $LOCK_PID)"
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# ── Prérequis ───────────────────────────────────────────────────────
if [ -z "$NODE" ]; then log "ERREUR - node introuvable"; exit 1; fi
if [ ! -f "$REFRESH_SCRIPT" ]; then log "ERREUR - $REFRESH_SCRIPT introuvable"; exit 1; fi

# ── Refresh ─────────────────────────────────────────────────────────
if OUTPUT=$("$NODE" "$REFRESH_SCRIPT" 2>&1); then
    log "OK - $OUTPUT"
else
    log "ERREUR - $OUTPUT"
    exit 1
fi
