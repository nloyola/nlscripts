#!/usr/bin/env bash
#
# immich-backup.sh - consistent backup of the Immich instance on berlix.
#
# Backs up the two things that matter and can't be regenerated:
#   1. The Postgres database  (albums, faces, users, metadata) -> fresh pg_dumpall
#   2. The original photos/videos (library/ + upload/)          -> rsync
# Regenerable derivatives (thumbs/, encoded-video/) are EXCLUDED by default
# (add --with-derivatives to include them and save regeneration time on restore).
#
# USAGE:
#   sudo immich-backup.sh /path/to/backup/dest [--with-derivatives] [--no-delete]
#
# RESTORE (summary):
#   1. Recreate the DB from the dump:
#        cat immich-db-<ts>.sql.gz | gunzip | \
#          docker exec -i immich_postgres psql -U immich -d postgres
#   2. Restore files:   rsync -aH  data/  /opt/nelson/immich/library/
#   3. Start Immich; it regenerates thumbnails/transcodes automatically.
#
set -euo pipefail

### ---- config ---------------------------------------------------------------
SRC="/opt/nelson/immich/library"      # Immich UPLOAD_LOCATION (originals live here)
PG_CONTAINER="immich_postgres"
PG_USER="immich"
KEEP_DUMPS=7                          # how many timestamped DB dumps to retain at dest
### ---------------------------------------------------------------------------

WITH_DERIVATIVES=0
RSYNC_DELETE="--delete"
DEST=""

usage() {
  cat <<EOF
immich-backup.sh - consistent backup of the Immich instance on berlix.

Backs up the two things that can't be regenerated:
  1. The Postgres database (albums, faces, users, metadata) -> fresh pg_dumpall
  2. The original photos/videos (library/ + upload/)         -> rsync
Regenerable derivatives (thumbs/, encoded-video/) are excluded by default.

USAGE:
  sudo immich-backup.sh <dest> [--with-derivatives] [--no-delete]

ARGUMENTS:
  <dest>               destination directory for the backup (required)

OPTIONS:
  --with-derivatives   also copy thumbs/ and encoded-video/ (~27 GB, regenerable)
  --no-delete          additive rsync; never delete files from the destination
  -h, --help           show this help and exit

EXAMPLES:
  sudo immich-backup.sh /mnt/backupdrive/immich
  sudo immich-backup.sh /mnt/backupdrive/immich --with-derivatives
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)          usage; exit 0 ;;
    --with-derivatives) WITH_DERIVATIVES=1 ;;
    --no-delete)        RSYNC_DELETE="" ;;
    -*)                 echo "unknown option: $arg" >&2; echo >&2; usage >&2; exit 2 ;;
    *)                  DEST="$arg" ;;
  esac
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

### ---- preflight -------------------------------------------------------------
[[ $EUID -eq 0 ]]        || die "must run as root (the library is root-owned): sudo $0 ..."
[[ -n "$DEST" ]]         || die "no destination given. usage: sudo $0 /path/to/dest [--with-derivatives] [--no-delete]"
[[ -d "$SRC" ]]          || die "source not found: $SRC"
command -v docker >/dev/null || die "docker not found"
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" || die "container $PG_CONTAINER is not running"
mkdir -p "$DEST" || die "cannot create/access dest: $DEST"

# single-instance lock so a scheduled run never overlaps a manual one
exec 9>"$DEST/.immich-backup.lock"
flock -n 9 || die "another immich-backup is already running against $DEST"

TS="$(date '+%Y%m%dT%H%M%S')"
DUMP="$DEST/immich-db-${TS}.sql.gz"

log "=== Immich backup starting -> $DEST ==="
log "source: $SRC   derivatives: $([[ $WITH_DERIVATIVES -eq 1 ]] && echo included || echo EXCLUDED)   delete: ${RSYNC_DELETE:-off}"

### ---- 1. database dump (do this first; files are immutable) -----------------
log "dumping database from $PG_CONTAINER ..."
# pipefail ensures a pg_dumpall failure aborts the script before we trust the file
docker exec -t "$PG_CONTAINER" pg_dumpall --clean --if-exists --username="$PG_USER" \
  | gzip > "$DUMP"
gzip -t "$DUMP" || die "DB dump is corrupt (gzip -t failed): $DUMP"
log "DB dump ok: $DUMP ($(du -h "$DUMP" | cut -f1))"

# prune old dumps, keep newest $KEEP_DUMPS
mapfile -t OLD < <(ls -1t "$DEST"/immich-db-*.sql.gz 2>/dev/null | tail -n +$((KEEP_DUMPS+1)) || true)
if ((${#OLD[@]})); then log "pruning ${#OLD[@]} old dump(s)"; rm -f "${OLD[@]}"; fi

### ---- 2. originals (and optionally derivatives) ----------------------------
RSYNC_EXCLUDES=( --exclude='.immich-backup.lock' )
if [[ $WITH_DERIVATIVES -eq 0 ]]; then
  RSYNC_EXCLUDES+=( --exclude='thumbs/' --exclude='encoded-video/' )
fi

log "rsyncing originals ..."
rsync -aH --stats --human-readable $RSYNC_DELETE \
  "${RSYNC_EXCLUDES[@]}" \
  "$SRC"/ "$DEST/data"/ \
  | grep -E 'Number of files:|regular files transferred|Total transferred|Total file size' || true

### ---- 3. summary ------------------------------------------------------------
log "backup sizes at destination:"
du -sh "$DEST/data" 2>/dev/null | sed 's/^/    originals+meta: /'
du -sh "$DEST"/immich-db-*.sql.gz 2>/dev/null | tail -1 | sed 's/^/    newest db dump: /'
df -h "$DEST" | tail -1 | awk '{print "    dest free: "$4" of "$2}'
log "=== Immich backup complete ==="
