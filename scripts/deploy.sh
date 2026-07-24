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

up_output="$(mktemp)"
if ! docker compose -f compose.production.yaml up -d --remove-orphans >"$up_output" 2>&1; then
  cat "$up_output"
  compose_project="$(docker compose -f compose.production.yaml config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
  storage_volume="${compose_project}_craft-storage"

  if grep -q "failed to mkdir .*${storage_volume}.*file exists" "$up_output" && docker volume inspect "$storage_volume" >/dev/null 2>&1; then
    echo "First start failed. Recreating the Craft storage volume and retrying..."
    docker compose -f compose.production.yaml down
    docker volume rm "$storage_volume" >/dev/null
    docker compose -f compose.production.yaml up -d --remove-orphans
  else
    exit 1
  fi
fi
rm -f "$up_output"

docker compose -f compose.production.yaml ps
