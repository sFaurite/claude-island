#!/bin/bash
# claude-stats-scheduler.sh
# Gestionnaire de rafraîchissement du cache stats de Claude Code.
#
# Politique :
#   - Live : toutes les heures (base scellée + données du jour)
#   - Force (recalcul complet de la base) : une fois par semaine (7+ jours sans force)
#
# Conçu pour tourner via cron toutes les heures. Le script Node gère
# lui-même la mise à jour incrémentale de la base et le calcul live.
#
# Cron : 0 * * * * /Users/faurite/Documents/Outils/ClaudeIsland/claude-island/scripts/claude-stats-scheduler.sh
#
# Fichier d'état : ~/.claude/stats-scheduler-state.json

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REFRESH_SCRIPT="$SCRIPT_DIR/refresh-claude-stats.mjs"
STATE_FILE="$HOME/.claude/stats-scheduler-state.json"
LOGFILE="/tmp/claude-stats-scheduler.log"
LOCKFILE="/tmp/claude-stats-scheduler.lock"
NODE="$(command -v node 2>/dev/null)"

# ── Logging ─────────────────────────────────────────────────────────

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

# ── Verrou ──────────────────────────────────────────────────────────

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

if [ -z "$NODE" ]; then
    log "ERREUR - node introuvable"
    exit 1
fi

if [ ! -f "$REFRESH_SCRIPT" ]; then
    log "ERREUR - $REFRESH_SCRIPT introuvable"
    exit 1
fi

# ── État du scheduler ───────────────────────────────────────────────

load_state() {
    if [ -f "$STATE_FILE" ]; then
        LAST_INCREMENTAL=$(jq -r '.lastIncremental // ""' "$STATE_FILE" 2>/dev/null)
        LAST_FORCE=$(jq -r '.lastForce // ""' "$STATE_FILE" 2>/dev/null)
    else
        LAST_INCREMENTAL=""
        LAST_FORCE=""
    fi
}

save_state() {
    local inc="${1:-$LAST_INCREMENTAL}"
    local force="${2:-$LAST_FORCE}"
    printf '{"lastIncremental":"%s","lastForce":"%s"}\n' "$inc" "$force" > "$STATE_FILE"
}

# ── Dates ───────────────────────────────────────────────────────────

TODAY=$(date '+%Y-%m-%d')

days_since() {
    local ref_date="$1"
    if [ -z "$ref_date" ]; then echo 999; return; fi
    local ref_epoch today_epoch
    # macOS
    ref_epoch=$(date -jf '%Y-%m-%d' "$ref_date" '+%s' 2>/dev/null)
    today_epoch=$(date '+%s')
    if [ -z "$ref_epoch" ]; then
        # Linux fallback
        ref_epoch=$(date -d "$ref_date" '+%s' 2>/dev/null || echo 0)
    fi
    echo $(( (today_epoch - ref_epoch) / 86400 ))
}

# ── Décision ────────────────────────────────────────────────────────

load_state

DAYS_SINCE_FORCE=$(days_since "$LAST_FORCE")

if [ -z "$LAST_FORCE" ] || [ "$DAYS_SINCE_FORCE" -ge 7 ]; then
    log "FORCE - Dernier force: ${LAST_FORCE:-jamais} (${DAYS_SINCE_FORCE}j)"
    if OUTPUT=$("$NODE" "$REFRESH_SCRIPT" --force 2>&1); then
        log "OK force - $OUTPUT"
        save_state "$TODAY" "$TODAY"
    else
        log "ERREUR force - $OUTPUT"
        exit 1
    fi
else
    log "LIVE - Rafraîchissement horaire (dernier force: $LAST_FORCE [${DAYS_SINCE_FORCE}j])"
    if OUTPUT=$("$NODE" "$REFRESH_SCRIPT" 2>&1); then
        log "OK live - $OUTPUT"
        save_state "$TODAY" "$LAST_FORCE"
    else
        log "ERREUR live - $OUTPUT"
        exit 1
    fi
fi
