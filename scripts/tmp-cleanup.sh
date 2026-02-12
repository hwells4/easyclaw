#!/usr/bin/env bash
# tmp-cleanup - Safe /tmp cleanup for VPS with coding agents
#
# Indexes CASS (if available) then removes stale temp files while
# preserving anything currently in use by active processes.
#
# Install: setup.sh installs this to ~/.local/bin/tmp-cleanup
# Cron:    Runs daily at 4am via crontab
# Logs:    journalctl -t tmp-cleanup

set -uo pipefail

LOG_TAG="tmp-cleanup"
DRY_RUN=false
VERBOSE=false
MAX_AGE_DAYS=2  # Remove files older than this many days

log() { logger -t "$LOG_TAG" "$1"; $VERBOSE && echo "$1" || true; }

usage() {
    echo "Usage: tmp-cleanup [--dry-run] [--verbose] [--max-age DAYS]"
    echo "  --dry-run   Show what would be deleted without deleting"
    echo "  --verbose   Print actions to stdout (useful for manual runs)"
    echo "  --max-age   Days before a file is considered stale (default: $MAX_AGE_DAYS)"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --verbose)  VERBOSE=true; shift ;;
        --max-age)  MAX_AGE_DAYS="$2"; shift 2 ;;
        --help|-h)  usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
done

log "Starting /tmp cleanup (max_age=${MAX_AGE_DAYS}d, dry_run=${DRY_RUN})"

# Record space before
BEFORE=$(df /tmp --output=used | tail -1 | tr -d ' ')

# ─── Step 1: Index CASS before cleanup ───────────────────────────────
# CASS stores its index in ~/.local/share/coding-agent-search/ (not /tmp)
# but we index first as a precaution to capture any recent session data.
if command -v cass &>/dev/null; then
    log "Running CASS index..."
    if cass index --json >/dev/null 2>&1; then
        log "CASS index completed successfully"
    else
        log "WARNING: CASS index failed (continuing with cleanup)"
    fi
fi

# ─── Step 2: Build list of paths currently open by processes ─────────
# We never delete files that are actively in use.
OPEN_DIRS=$(mktemp)
trap 'rm -f "$OPEN_DIRS"' EXIT

lsof +D /tmp 2>/dev/null \
    | awk 'NR>1 {print $9}' \
    | sed 's|^/tmp/\([^/]*\).*|/tmp/\1|' \
    | sort -u > "$OPEN_DIRS" 2>/dev/null || true

log "Found $(wc -l < "$OPEN_DIRS") paths with open file handles"

# ─── Step 3: Define what to always preserve ──────────────────────────
PRESERVE_PATTERNS=(
    "tmux-*"                  # tmux sockets
    ".X11-unix"               # X11 sockets
    ".ICE-unix"               # ICE sockets
    ".XIM-unix"               # XIM sockets
    ".font-unix"              # Font sockets
    "systemd-private-*"       # systemd service private tmp
    "snap.*"                  # snap packages
    "ssh-*"                   # SSH agent sockets
    "agent-browser-*.sock"    # Active browser agent sockets
    "agent-browser-*.pid"     # Active browser agent PIDs
)

is_preserved() {
    local name
    name=$(basename "$1")
    for pattern in "${PRESERVE_PATTERNS[@]}"; do
        # shellcheck disable=SC2254
        case "$name" in $pattern) return 0 ;; esac
    done
    return 1
}

is_open() {
    grep -Fxq "$1" "$OPEN_DIRS"
}

# ─── Step 4: Clean stale files and directories ───────────────────────
CLEANED=0
SKIPPED=0
FREED=0

for entry in /tmp/* /tmp/.*; do
    name=$(basename "$entry")
    [[ "$name" == "." || "$name" == ".." ]] && continue
    [[ -e "$entry" ]] || continue

    if is_preserved "$entry"; then
        log "PRESERVE (pattern): $name"
        ((SKIPPED++)) || true
        continue
    fi

    if is_open "$entry"; then
        log "PRESERVE (in-use): $name"
        ((SKIPPED++)) || true
        continue
    fi

    # Check age - skip if newer than MAX_AGE_DAYS
    if [[ -d "$entry" ]]; then
        newest=$(find "$entry" -type f -mtime -"$MAX_AGE_DAYS" -print -quit 2>/dev/null)
        if [[ -n "$newest" ]]; then
            $VERBOSE && log "PRESERVE (recent content): $name"
            ((SKIPPED++)) || true
            continue
        fi
    else
        if find "$entry" -maxdepth 0 -mtime -"$MAX_AGE_DAYS" -print -quit 2>/dev/null | /usr/bin/grep -q .; then
            $VERBOSE && log "PRESERVE (recent): $name"
            ((SKIPPED++)) || true
            continue
        fi
    fi

    SIZE=$(du -sk "$entry" 2>/dev/null | cut -f1)

    if $DRY_RUN; then
        log "WOULD REMOVE: $name (${SIZE}K)"
    else
        if rm -rf "$entry" 2>/dev/null; then
            log "REMOVED: $name (${SIZE}K)"
            ((FREED += SIZE)) || true
        else
            log "FAILED to remove: $name"
        fi
    fi
    ((CLEANED++)) || true
done

# ─── Step 5: Summary ─────────────────────────────────────────────────
AFTER=$(df /tmp --output=used | tail -1 | tr -d ' ')
ACTUAL_FREED=$(( (BEFORE - AFTER) ))

if $DRY_RUN; then
    log "Dry run complete: would clean $CLEANED items, preserved $SKIPPED"
else
    log "Cleanup complete: removed $CLEANED items (~${FREED}K), preserved $SKIPPED, actual space freed: ${ACTUAL_FREED}K"
fi
