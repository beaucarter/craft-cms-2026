#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
REVISION="${1:-origin/main}"

if [[ ! -f .env.production ]]; then
  echo "Missing .env.production. Copy and configure .env.production.example first." >&2
  exit 1
fi

git fetch --prune origin main
git checkout --force "$REVISION"

docker compose -f compose.production.yaml build --pull
docker compose -f compose.production.yaml up -d --remove-orphans
docker compose -f compose.production.yaml ps

