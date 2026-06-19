#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

REPOSITORY_URL="${1:-}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
APP_PATH="/opt/craft-cms-2026"

apt-get update
apt-get install -y ca-certificates curl git ufw

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

id "$DEPLOY_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$DEPLOY_USER"
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_PATH"

ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

if [[ -n "$REPOSITORY_URL" ]]; then
  sudo -u "$DEPLOY_USER" git clone "$REPOSITORY_URL" "$APP_PATH"
fi

echo
echo "Droplet provisioned."
echo "Add the GitHub Actions public key to /home/$DEPLOY_USER/.ssh/authorized_keys."
echo "Then create $APP_PATH/.env.production from .env.production.example."
