#!/usr/bin/env sh
set -eu

mkdir -p storage/runtime storage/logs web/cpresources web/uploads web/imager
chown -R www-data:www-data storage web/cpresources web/uploads web/imager

if php craft install/check >/dev/null 2>&1; then
  su -s /bin/sh www-data -c 'php craft up --interactive=0'
elif [ "${1:-}" != "apache2-foreground" ]; then
  echo "Waiting for Craft's first-time installation..."
  until php craft install/check >/dev/null 2>&1; do
    sleep 10
  done
  su -s /bin/sh www-data -c 'php craft up --interactive=0'
fi

exec "$@"
