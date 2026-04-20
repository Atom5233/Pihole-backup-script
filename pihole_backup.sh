#!/bin/bash
# pihole_backup.sh
#
# Backs up Pi-hole, dnsmasq, and Unbound configuration to a NAS mount.
# Produces one dated snapshot per day and enforces a rolling 7-day retention policy.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

MAILTO=root

readonly MOUNT="/mnt/backup"
readonly BASE_DIR="$MOUNT/pihole"
readonly LOG_LOCAL="/var/log/pihole_backup.log"
readonly LOG_TAG="pihole-backup"
readonly KEEP_DAYS=7
readonly DATE="$(date +%F)"

readonly SOURCES=(
    /etc/pihole
    /etc/dnsmasq.d
    /etc/unbound/unbound.conf.d
)

# ── Exclusive lock ───────────────────────────────────────────────────────────
# Acquire a non-blocking lock to prevent concurrent executions.

LOCKFILE="/var/run/pihole_backup.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[ERR] Another backup is already running"; exit 1; }

# ── Helper functions ─────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local msg="[${level}] $* — $(date)"

    if command -v systemd-cat >/dev/null 2>&1; then
        echo "$msg" | systemd-cat -t "$LOG_TAG" -p "${level,,}"
    fi

    if [[ -w "$BASE_DIR" ]]; then
        echo "$msg" >> "$BASE_DIR/backup.log"
        trim_log "$BASE_DIR/backup.log"
    else
        echo "$msg" >> "$LOG_LOCAL"
    fi
}

trim_log() {
    local logfile="$1"
    local tmp
    tmp="$(mktemp)" || return
    tail -n 1000 "$logfile" > "$tmp" && mv "$tmp" "$logfile" || rm -f "$tmp"
}

die() {
    log ERR "$@"
    exit 1
}

# ── Pre-flight checks ────────────────────────────────────────────────────────

mountpoint -q "$MOUNT" || die "NAS not mounted at $MOUNT"

timeout 5 test -w "$MOUNT" || die "NAS mount not writable"

mkdir -p "$BASE_DIR" || die "Could not create $BASE_DIR"

# ── Backup paths ─────────────────────────────────────────────────────────────

readonly BACKUP_DIR="$BASE_DIR/$DATE"
readonly BACKUP_TMP="$BASE_DIR/.tmp_$DATE"

if [[ -d "$BACKUP_DIR" ]]; then
    log WARN "Backup for $DATE already exists, skipping"
    rm -rf "$BACKUP_TMP" 2>/dev/null || true
    exit 0
fi

mkdir -p "$BACKUP_TMP" || die "Could not create temp dir"

# Register a cleanup handler to remove the incomplete temp directory on any unexpected exit.
trap 'log WARN "Backup interrupted, temp dir cleaned up"; rm -rf "$BACKUP_TMP"' EXIT

# ── Sync sources ────────────────────────────────────────────────────────────

FAILED=0

for src in "${SOURCES[@]}"; do
    if [[ ! -e "$src" ]]; then
        log WARN "Missing source: $src"
        continue
    fi

    # --relative preserves the absolute source path within the backup tree
        # (e.g. BACKUP_TMP/etc/pihole/ rather than BACKUP_TMP/pihole/),
        # ensuring the provenance of each file is unambiguous at restore time.
    rsync -a --delete --relative "$src" "$BACKUP_TMP/" \
        >> "$BASE_DIR/backup.log" 2>&1 \
        || { log ERR "rsync failed: $src"; FAILED=1; }
done

# ── Validation ──────────────────────────────────────────────────────────────

if [[ "$FAILED" -ne 0 ]]; then
    rm -rf "$BACKUP_TMP"
    die "One or more rsync operations failed"
fi

file_count=$(find "$BACKUP_TMP" -type f | wc -l | tr -d ' ')

if [[ "$file_count" -eq 0 ]]; then
    rm -rf "$BACKUP_TMP"
    die "Backup is empty — aborting"
fi

# ── Promote backup ───────────────────────────────────────────────────────────

mv "$BACKUP_TMP" "$BACKUP_DIR" || die "Promotion failed"

trap - EXIT   # Disarm the cleanup handler; the backup completed successfully.

log INFO "Backup complete ($file_count files) → $BACKUP_DIR"

# ── Retention policy ─────────────────────────────────────────────────────────
# Remove dated snapshot directories older than KEEP_DAYS.
# The name glob restricts deletion to directories created by this script.

find "$BASE_DIR" \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -name "20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]" \
    -mtime "+${KEEP_DAYS}" \
    -exec rm -rf "{}" \; \
    || log WARN "Rotation encountered issues"
