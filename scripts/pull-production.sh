#!/usr/bin/env bash
set -euo pipefail

SYNC_ENV_FILE="${SYNC_ENV_FILE:-.env.sync}"
if [[ -f "$SYNC_ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SYNC_ENV_FILE"
  set +a
fi

PRODUCTION_HOST="${PRODUCTION_HOST:-}"
PRODUCTION_USER="${PRODUCTION_USER:-deploy}"
PRODUCTION_PATH="${PRODUCTION_PATH:-/opt/craft-cms-2026}"
PRODUCTION_SSH_KEY="${PRODUCTION_SSH_KEY:-}"
ASSUME_YES=false
HOST_ARGUMENT_SET=false

for argument in "$@"; do
  case "$argument" in
    --yes) ASSUME_YES=true ;;
    *)
      if [[ "$HOST_ARGUMENT_SET" == false ]]; then
        PRODUCTION_HOST="$argument"
        HOST_ARGUMENT_SET=true
      else
        echo "Unexpected argument: $argument" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PRODUCTION_HOST" ]]; then
  echo "Usage: $0 [--yes] DROPLET_IP" >&2
  echo "Or copy .env.sync.example to .env.sync and set PRODUCTION_HOST." >&2
  exit 1
fi

if ! command -v ddev >/dev/null 2>&1; then
  echo "DDEV is required." >&2
  exit 1
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Replace the local database and uploads with production? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 0
fi

ssh_command=(ssh -o IdentitiesOnly=yes)
if [[ -n "$PRODUCTION_SSH_KEY" ]]; then
  ssh_command+=(-i "$PRODUCTION_SSH_KEY")
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
database_dump="$temporary_directory/database.sql.gz"
uploads_directory="$temporary_directory/uploads"
mkdir -p "$uploads_directory" web/uploads

echo "Downloading the production database..."
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
  "cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml exec -T database sh -lc 'pg_dump --no-owner --no-acl -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\"'" \
  | gzip > "$database_dump"

echo "Importing the production database into DDEV..."
ddev start
ddev import-db --file="$database_dump"

echo "Downloading production uploads..."
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
  "cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml exec -T app tar -C /var/www/html/web/uploads -czf - ." \
  | tar -xzf - -C "$uploads_directory"
rsync -a --delete "$uploads_directory/" web/uploads/

echo "Applying migrations and Project Config locally..."
ddev craft up --interactive=0

echo "Local database and uploads now match production."
