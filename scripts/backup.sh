#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
BACKUP_DIR="${BACKUP_DIR:-./backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$BACKUP_DIR"
docker compose -f compose.production.yaml exec -T database \
  sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  | gzip > "$BACKUP_DIR/database-$STAMP.sql.gz"

find "$BACKUP_DIR" -type f -name 'database-*.sql.gz' -mtime "+$KEEP_DAYS" -delete
echo "Created $BACKUP_DIR/database-$STAMP.sql.gz"
