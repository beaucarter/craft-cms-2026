#!/usr/bin/env bash
set -euo pipefail

TEMPLATE_REPOSITORY="${TEMPLATE_REPOSITORY:-beaucarter/craft-cms-2026}"
REGION="${REGION:-syd1}"
SIZE="${SIZE:-s-2vcpu-2gb}"
IMAGE="${IMAGE:-ubuntu-24-04-x64}"
DOCTL_CONTEXT="${DOCTL_CONTEXT:-}"
DESTINATION_PARENT="${DESTINATION_PARENT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-${SSH_PUBLIC_KEY%.pub}}"
VISIBILITY="private"
ASSUME_YES=false
DRY_RUN=false
INSTALL_CRAFT=true
OWNER=""
SLUG=""
TITLE=""

usage() {
  cat <<'EOF'
Create a complete Craft CMS site from this template.

Usage:
  ./scripts/new-site.sh [options] SITE-SLUG "Site Name"

Options:
  --owner OWNER          GitHub user or organization (defaults to current user)
  --public               Create a public repository (default: private)
  --private              Create a private repository
  --region REGION        DigitalOcean region (default: syd1)
  --size SIZE            DigitalOcean size (default: s-2vcpu-2gb)
  --do-context CONTEXT   doctl authentication context
  --destination PATH     Parent directory for the clone
  --skip-craft-install   Leave local and production at the Craft installer
  --yes                  Skip the billable-resource confirmation
  --dry-run              Validate inputs and show the plan without creating anything
  -h, --help             Show this help

Optional environment variables:
  ADMIN_EMAIL, ADMIN_USERNAME, ADMIN_PASSWORD
  TEMPLATE_REPOSITORY, SSH_PUBLIC_KEY, SSH_PRIVATE_KEY
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="${2:-}"; shift 2 ;;
    --public) VISIBILITY="public"; shift ;;
    --private) VISIBILITY="private"; shift ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --size) SIZE="${2:-}"; shift 2 ;;
    --do-context) DOCTL_CONTEXT="${2:-}"; shift 2 ;;
    --destination) DESTINATION_PARENT="${2:-}"; shift 2 ;;
    --skip-craft-install) INSTALL_CRAFT=false; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) die "Unknown option: $1" ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      elif [[ -z "$TITLE" ]]; then
        TITLE="$1"
      else
        die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$SLUG" ]] || { usage; die "SITE-SLUG is required."; }
[[ -n "$TITLE" ]] || { usage; die "Site Name is required."; }
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$ ]] || die "SITE-SLUG must contain lowercase letters, numbers, and hyphens only."
[[ "$TITLE" != *"'"* && "$TITLE" != *"\\"* ]] || die "Site Name cannot contain apostrophes or backslashes."

require_command gh
require_command doctl
require_command jq
require_command git
require_command ssh
require_command ssh-keygen
require_command ssh-keyscan
require_command scp
require_command curl
require_command openssl
require_command perl
require_command ddev
require_command pnpm

[[ -f "$SSH_PUBLIC_KEY" ]] || die "SSH public key not found: $SSH_PUBLIC_KEY"
[[ -f "$SSH_PRIVATE_KEY" ]] || die "SSH private key not found: $SSH_PRIVATE_KEY"
mkdir -p "$DESTINATION_PARENT"
DESTINATION_PARENT="$(cd "$DESTINATION_PARENT" && pwd)"
TARGET_DIRECTORY="$DESTINATION_PARENT/$SLUG"
[[ ! -e "$TARGET_DIRECTORY" ]] || die "Destination already exists: $TARGET_DIRECTORY"

gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login"
if [[ -z "$OWNER" ]]; then
  OWNER="$(gh api user --jq .login)"
fi
REPOSITORY="$OWNER/$SLUG"

doctl_args=()
if [[ -n "$DOCTL_CONTEXT" ]]; then
  doctl_args+=(--context "$DOCTL_CONTEXT")
elif doctl auth list 2>/dev/null | grep -qx 'craft-cms-2026'; then
  doctl_args+=(--context craft-cms-2026)
fi
doctl account get "${doctl_args[@]}" >/dev/null

size_json="$(doctl compute size list "${doctl_args[@]}" --output json)"
plan="$(jq -r --arg size "$SIZE" --arg region "$REGION" '
  .[] | select(.slug == $size and (.regions | index($region))) |
  [.price_monthly, .price_hourly, .vcpus, .memory, .disk] | @tsv
' <<<"$size_json" | head -1)"
[[ -n "$plan" ]] || die "Size $SIZE is unavailable in $REGION."
IFS=$'\t' read -r monthly_price hourly_price vcpus memory disk <<<"$plan"

echo
echo "New site plan"
echo "  Repository:  $REPOSITORY ($VISIBILITY)"
echo "  Clone:       $TARGET_DIRECTORY"
echo "  Droplet:     $SLUG in $REGION"
echo "  Resources:   $vcpus vCPU, $((memory / 1024)) GB RAM, $disk GB disk"
echo "  Price:       US\$$monthly_price/month (US\$$hourly_price/hour)"
echo "  Craft seed:  $INSTALL_CRAFT"
echo

if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run complete. No resources were created."
  exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Create the GitHub repository and billable Droplet? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || exit 0
fi

if gh repo view "$REPOSITORY" >/dev/null 2>&1; then
  die "GitHub repository already exists: $REPOSITORY"
fi
if doctl compute droplet list "${doctl_args[@]}" --format Name --no-header | grep -qx "$SLUG"; then
  die "DigitalOcean Droplet already exists: $SLUG"
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

echo "Creating and cloning the GitHub repository..."
visibility_flag="--$VISIBILITY"
(
  cd "$DESTINATION_PARENT"
  gh repo create "$REPOSITORY" \
    --template "$TEMPLATE_REPOSITORY" \
    "$visibility_flag" \
    --clone \
    --description "$TITLE — Craft CMS website"
)

echo "Renaming template identifiers..."
(
  cd "$TARGET_DIRECTORY"
  while IFS= read -r -d '' file; do
    OLD_VALUE='craft-cms-2026' NEW_VALUE="$SLUG" perl -0pi -e 's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g' "$file"
  done < <(git grep -Ilz 'craft-cms-2026')
  while IFS= read -r -d '' file; do
    OLD_VALUE='Craft CMS 2026' NEW_VALUE="$TITLE" perl -0pi -e 's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g' "$file"
  done < <(git grep -Ilz 'Craft CMS 2026')

  owner_lower="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  OLD_VALUE="beaucarter/$SLUG" NEW_VALUE="$owner_lower/$SLUG" perl -0pi -e 's/\Q$ENV{OLD_VALUE}\E/$ENV{NEW_VALUE}/g' composer.json

  cp .env.example.dev .env
  local_security_key="$(openssl rand -hex 32)"
  SECURITY_KEY="$local_security_key" perl -0pi -e 's/^CRAFT_SECURITY_KEY=$/CRAFT_SECURITY_KEY=$ENV{SECURITY_KEY}/m' .env

  git add --all
  git commit -m "Initialize $TITLE"
  git push origin main
)

admin_email="${ADMIN_EMAIL:-}"
admin_username="${ADMIN_USERNAME:-admin}"
admin_password="${ADMIN_PASSWORD:-}"

echo "Preparing the local development environment..."
(
  cd "$TARGET_DIRECTORY"
  ddev start
  ddev composer install
  pnpm install --frozen-lockfile
  pnpm build
)

if [[ "$INSTALL_CRAFT" == true ]]; then
  if [[ -z "$admin_email" ]]; then
    read -r -p "Craft administrator email: " admin_email
  fi
  if [[ -z "$admin_password" ]]; then
    read -r -s -p "Craft administrator password (12+ characters): " admin_password
    echo
  fi
  [[ "$admin_email" == *@* ]] || die "A valid administrator email is required."
  [[ ${#admin_password} -ge 12 ]] || die "Administrator password must be at least 12 characters."

  echo "Installing Craft locally..."
  (
    cd "$TARGET_DIRECTORY"
    ddev craft install \
      --interactive=0 \
      --username="$admin_username" \
      --password="$admin_password" \
      --email="$admin_email" \
      --site-name="$TITLE" \
      --site-url="https://$SLUG.ddev.site" \
      --language=en-AU
    ddev craft up --interactive=0
  )
fi

echo "Finding or importing the DigitalOcean SSH key..."
key_fingerprint="$(ssh-keygen -E md5 -lf "$SSH_PUBLIC_KEY" | awk '{print $2}' | sed 's/^MD5://')"
digitalocean_key_id="$(doctl compute ssh-key list "${doctl_args[@]}" --output json | jq -r --arg fingerprint "$key_fingerprint" '.[] | select(.fingerprint == $fingerprint) | .id' | head -1)"
if [[ -z "$digitalocean_key_id" ]]; then
  digitalocean_key_id="$(doctl compute ssh-key import "$SLUG-local" "${doctl_args[@]}" --public-key-file "$SSH_PUBLIC_KEY" --format ID --no-header)"
fi

echo "Creating the DigitalOcean Droplet..."
droplet_output="$(doctl compute droplet create "$SLUG" \
  "${doctl_args[@]}" \
  --region "$REGION" \
  --image "$IMAGE" \
  --size "$SIZE" \
  --ssh-keys "$digitalocean_key_id" \
  --enable-monitoring \
  --enable-ipv6 \
  --wait \
  --format PublicIPv4 \
  --no-header)"
droplet_ip="$(awk 'NF {print $1; exit}' <<<"$droplet_output")"
[[ -n "$droplet_ip" ]] || die "Droplet was created but no public IP was returned."
echo "Droplet IP: $droplet_ip"

root_ssh=(ssh -i "$SSH_PRIVATE_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new "root@$droplet_ip")
root_scp=(scp -i "$SSH_PRIVATE_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)

echo "Waiting for SSH and provisioning Ubuntu..."
for attempt in $(seq 1 36); do
  if "${root_ssh[@]}" 'cloud-init status --wait >/dev/null 2>&1' 2>/dev/null; then
    break
  fi
  [[ "$attempt" -lt 36 ]] || die "Timed out waiting for Droplet SSH."
  sleep 5
done
"${root_ssh[@]}" "APP_PATH='/opt/$SLUG' bash -s" < "$TARGET_DIRECTORY/scripts/provision-ubuntu.sh"
"${root_ssh[@]}" 'cat >> /home/deploy/.ssh/authorized_keys; sort -u /home/deploy/.ssh/authorized_keys -o /home/deploy/.ssh/authorized_keys; chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 600 /home/deploy/.ssh/authorized_keys' < "$SSH_PUBLIC_KEY"

echo "Configuring read-only repository access..."
repository_key="$temporary_directory/repository-key"
ssh-keygen -q -t ed25519 -N '' -C "$SLUG-repository" -f "$repository_key"
gh repo deploy-key add "$repository_key.pub" --repo "$REPOSITORY" --title "$SLUG Droplet read-only"
ssh-keyscan github.com > "$temporary_directory/github-known-hosts" 2>/dev/null
"${root_scp[@]}" "$repository_key" "$temporary_directory/github-known-hosts" "root@$droplet_ip:/tmp/"
"${root_ssh[@]}" "install -m 600 -o deploy -g deploy /tmp/repository-key /home/deploy/.ssh/github_repository; install -m 600 -o deploy -g deploy /tmp/github-known-hosts /home/deploy/.ssh/known_hosts; printf '%s\n' 'Host github.com' '  IdentityFile /home/deploy/.ssh/github_repository' '  IdentitiesOnly yes' > /home/deploy/.ssh/config; chown deploy:deploy /home/deploy/.ssh/config; chmod 600 /home/deploy/.ssh/config; sudo -u deploy git clone 'git@github.com:$REPOSITORY.git' '/opt/$SLUG'"

echo "Creating production secrets and starting the site..."
"${root_ssh[@]}" "cd '/opt/$SLUG'; cp .env.production.example .env.production; db_password=\$(openssl rand -hex 32); security_key=\$(openssl rand -hex 32); sed -i \"s|http://YOUR_DROPLET_IP|http://$droplet_ip|; s|CRAFT_SECURITY_KEY=REPLACE_WITH_A_LONG_RANDOM_VALUE|CRAFT_SECURITY_KEY=\$security_key|; s|CRAFT_DB_PASSWORD=REPLACE_WITH_A_LONG_RANDOM_VALUE|CRAFT_DB_PASSWORD=\$db_password|; s|POSTGRES_PASSWORD=REPLACE_WITH_A_LONG_RANDOM_VALUE|POSTGRES_PASSWORD=\$db_password|\" .env.production; chown deploy:deploy .env.production; chmod 600 .env.production; if ! swapon --show | grep -q /swapfile; then fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile; echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi; sudo -u deploy ./scripts/deploy.sh main"

if [[ "$INSTALL_CRAFT" == true ]]; then
  echo "Copying the local Craft database to production..."
  (
    cd "$TARGET_DIRECTORY"
    ddev export-db --file="$temporary_directory/local.sql.gz"
  )
  gzip -dc "$temporary_directory/local.sql.gz" | sed 's/OWNER TO db;/OWNER TO craft;/g' | gzip > "$temporary_directory/production.sql.gz"
  "${root_scp[@]}" "$temporary_directory/production.sql.gz" "root@$droplet_ip:/tmp/$SLUG.sql.gz"
  "${root_ssh[@]}" "cd '/opt/$SLUG' && docker compose -f compose.production.yaml stop app queue caddy && docker compose -f compose.production.yaml exec -T database psql -U craft -d craft -v ON_ERROR_STOP=1 -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION craft;' && gzip -dc '/tmp/$SLUG.sql.gz' | docker compose -f compose.production.yaml exec -T database psql -U craft -d craft -v ON_ERROR_STOP=1 >/dev/null && rm -f '/tmp/$SLUG.sql.gz' && docker compose -f compose.production.yaml up -d --remove-orphans"
fi

echo "Configuring GitHub Actions deployment credentials..."
actions_key="$temporary_directory/actions-key"
ssh-keygen -q -t ed25519 -N '' -C "github-actions-$SLUG" -f "$actions_key"
"${root_ssh[@]}" 'cat >> /home/deploy/.ssh/authorized_keys; sort -u /home/deploy/.ssh/authorized_keys -o /home/deploy/.ssh/authorized_keys; chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 600 /home/deploy/.ssh/authorized_keys' < "$actions_key.pub"
ssh-keyscan -H "$droplet_ip" > "$temporary_directory/droplet-known-hosts" 2>/dev/null

gh api --method PUT "repos/$REPOSITORY/environments/production" >/dev/null
gh secret set DROPLET_HOST --env production --repo "$REPOSITORY" --body "$droplet_ip"
gh secret set DROPLET_USER --env production --repo "$REPOSITORY" --body deploy
gh secret set DROPLET_SSH_PRIVATE_KEY --env production --repo "$REPOSITORY" < "$actions_key"
gh secret set DROPLET_KNOWN_HOSTS --env production --repo "$REPOSITORY" < "$temporary_directory/droplet-known-hosts"
gh variable set DEPLOY_ENABLED --repo "$REPOSITORY" --body true

printf 'PRODUCTION_HOST=%s\nPRODUCTION_USER=deploy\n' "$droplet_ip" > "$TARGET_DIRECTORY/.env.sync"

echo "Verifying production..."
for attempt in $(seq 1 24); do
  if curl --fail --silent --show-error "http://$droplet_ip/health.php" >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" -lt 24 ]] || die "Production did not become healthy at http://$droplet_ip/health.php"
  sleep 5
done

admin_path="admin/install"
if [[ "$INSTALL_CRAFT" == true ]]; then
  admin_path="admin/login"
fi

echo
echo "Site created successfully."
echo "  Local:       https://$SLUG.ddev.site"
echo "  Production:  http://$droplet_ip"
echo "  Admin:       http://$droplet_ip/$admin_path"
echo "  Repository:  https://github.com/$REPOSITORY"
echo "  Directory:   $TARGET_DIRECTORY"
echo
echo "Add a domain later by updating SITE_ADDRESS and PRIMARY_SITE_URL in /opt/$SLUG/.env.production."
