#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

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
SKIP_UPLOADS=false
HOST_ARGUMENT_SET=false

for argument in "$@"; do
  case "$argument" in
    --yes) ASSUME_YES=true ;;
    --skip-uploads) SKIP_UPLOADS=true ;;
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
  echo "Usage: $0 [--yes] [--skip-uploads] DROPLET_IP" >&2
  echo "Or copy .env.sync.example to .env.sync and set PRODUCTION_HOST." >&2
  exit 1
fi

for command_name in ddev ssh scp gzip sed tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

ssh_command=(ssh -o IdentitiesOnly=yes)
scp_command=(scp -o IdentitiesOnly=yes)
if [[ -n "$PRODUCTION_SSH_KEY" ]]; then
  ssh_command+=(-i "$PRODUCTION_SSH_KEY")
  scp_command+=(-i "$PRODUCTION_SSH_KEY")
fi

site_name="$(basename "$PRODUCTION_PATH")"

if [[ "$ASSUME_YES" != true ]]; then
  echo "This will replace the PRODUCTION database${SKIP_UPLOADS:+} with your LOCAL database."
  if [[ "$SKIP_UPLOADS" == false ]]; then
    echo "It will also replace production uploads with your local web/uploads folder."
  fi
  echo
  echo "Production host: $PRODUCTION_HOST"
  echo "Production path: $PRODUCTION_PATH"
  echo
  read -r -p "Type '$site_name' to continue: " reply
  [[ "$reply" == "$site_name" ]] || exit 0
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
local_database="$temporary_directory/local.sql.gz"
production_database="$temporary_directory/production.sql.gz"
remote_database="/tmp/$site_name-local-$timestamp.sql.gz"

echo "Checking production access..."
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" "test -d '$PRODUCTION_PATH' && cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml ps >/dev/null"

echo "Ensuring production is running for backups..."
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
  "cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml up -d app"

echo "Creating production backups on the Droplet..."
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
  "cd '$PRODUCTION_PATH' && mkdir -p backups && docker compose -f compose.production.yaml exec -T database sh -lc 'pg_dump --no-owner --no-acl -U \"\$POSTGRES_USER\" \"\$POSTGRES_DB\"' | gzip > 'backups/push-production-database-$timestamp.sql.gz'"

if [[ "$SKIP_UPLOADS" == false ]]; then
  "${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
    "cd '$PRODUCTION_PATH' && mkdir -p backups && docker compose -f compose.production.yaml exec -T app tar -C /var/www/html/web/uploads -czf - . > 'backups/push-production-uploads-$timestamp.tar.gz'"
fi

echo "Exporting the local DDEV database..."
ddev start
ddev export-db --file="$local_database"
gzip -dc "$local_database" | sed 's/OWNER TO db;/OWNER TO craft;/g' | gzip > "$production_database"

echo "Uploading and importing the local database..."
"${scp_command[@]}" "$production_database" "$PRODUCTION_USER@$PRODUCTION_HOST:$remote_database"
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
  "cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml stop app queue caddy && docker compose -f compose.production.yaml exec -T database psql -U craft -d craft -v ON_ERROR_STOP=1 -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION craft;' && gzip -dc '$remote_database' | docker compose -f compose.production.yaml exec -T database psql -U craft -d craft -v ON_ERROR_STOP=1 >/dev/null && rm -f '$remote_database' && docker compose -f compose.production.yaml up -d app"

if [[ "$SKIP_UPLOADS" == false ]]; then
  echo "Replacing production uploads with local uploads..."
  mkdir -p web/uploads
  tar -C web/uploads -czf - . | "${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
    "cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml exec -T app sh -lc 'mkdir -p /var/www/html/web/uploads && find /var/www/html/web/uploads -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -C /var/www/html/web/uploads -xzf - && chown -R www-data:www-data /var/www/html/web/uploads'"
fi

echo "Restarting production and applying migrations/project config..."
"${ssh_command[@]}" "$PRODUCTION_USER@$PRODUCTION_HOST" \
  "cd '$PRODUCTION_PATH' && docker compose -f compose.production.yaml up -d --remove-orphans && docker compose -f compose.production.yaml exec -T app su -s /bin/sh www-data -c 'php craft up --interactive=0'"

if [[ "$SKIP_UPLOADS" == true ]]; then
  echo "Local database has been pushed to production."
else
  echo "Local database and uploads have been pushed to production."
fi
echo "Backups were saved in $PRODUCTION_PATH/backups on the Droplet."
