# Craft CMS 2026

A reusable Craft CMS 5 starter with Tailwind CSS 4, Vite, DDEV, PostgreSQL, Docker, and GitHub-to-DigitalOcean Droplet deployment.

## What is included

- Craft CMS 5 and Twig
- Tailwind CSS 4 compiled by Vite
- DDEV local environment with PHP 8.4 and PostgreSQL 16
- Production containers for Craft/Apache, PostgreSQL, a queue worker, and Caddy
- Automatic HTTPS after a hostname is configured
- GitHub Actions checks and production deployment

## Start locally

Requirements: Docker Desktop, DDEV, and Node.js/pnpm (or use the versions inside DDEV).

```bash
git clone YOUR_REPOSITORY_URL craft-cms-2026
cd craft-cms-2026
cp .env.example.dev .env
ddev start
ddev composer install
ddev pnpm install
ddev pnpm build
ddev craft setup
ddev launch
```

Use `ddev pnpm dev` in a second terminal while styling. It watches Twig, CSS, and JavaScript and rebuilds `web/dist`.

Project Config under `config/project/` must be committed after settings or content-model changes. Production has admin changes disabled; deployments apply migrations and Project Config automatically with `craft up`.

## Deploy to a DigitalOcean Droplet

Use an Ubuntu LTS Droplet with at least 2 GB RAM. Add your SSH key during creation. A basic firewall is configured by the provisioning script.

### 1. Provision the server

Copy this repository's `scripts/provision-ubuntu.sh` to the Droplet and run it as root. For a public repository, pass its HTTPS clone URL:

```bash
sudo bash provision-ubuntu.sh https://github.com/YOUR_ACCOUNT/craft-cms-2026.git
```

For a private repository, first create a read-only GitHub deploy key for the `deploy` user, then clone its SSH URL into `/opt/craft-cms-2026`.

### 2. Configure production

On the Droplet:

```bash
cd /opt/craft-cms-2026
cp .env.production.example .env.production
openssl rand -base64 48
nano .env.production
```

Initially set `SITE_ADDRESS=:80` and `PRIMARY_SITE_URL=http://DROPLET_IP`. Use unique random values for `CRAFT_SECURITY_KEY` and the matching Craft/Postgres database passwords.

Deploy once:

```bash
./scripts/deploy.sh main
```

Visit `http://DROPLET_IP/admin/install` to create the site and first administrator.

### 3. Connect GitHub Actions

Create a dedicated SSH key pair for GitHub Actions. Put its public key in `/home/deploy/.ssh/authorized_keys` on the Droplet, then add these GitHub repository environment secrets under the `production` environment:

- `DROPLET_HOST`: the Droplet IP
- `DROPLET_USER`: `deploy`
- `DROPLET_SSH_PRIVATE_KEY`: the private deployment key
- `DROPLET_KNOWN_HOSTS`: output from `ssh-keyscan -H DROPLET_IP`

Add a repository variable named `DEPLOY_ENABLED` with the value `true` when the Droplet is ready. Until then, production deployment is safely skipped.

A push to `main` then deploys that exact commit. Pull requests and pushes also run Composer validation, PHP linting, and the frontend build.

### 4. Add a hostname and HTTPS

Create an `A` record pointing a subdomain to the Droplet IP. After DNS resolves, update `.env.production`:

```dotenv
SITE_ADDRESS=craft.example.com
PRIMARY_SITE_URL=https://craft.example.com
```

Run `docker compose -f compose.production.yaml up -d`. Caddy obtains and renews the TLS certificate automatically.

## Backups

Droplet backups are useful, but also schedule application-aware database backups:

```bash
cd /opt/craft-cms-2026
./scripts/backup.sh
```

The script keeps 14 days by default. Copy the resulting files off the Droplet (for example to DigitalOcean Spaces) and separately back up the `craft-uploads` Docker volume.

## Useful commands

```bash
# Local Craft CLI
ddev craft help

# Production logs
docker compose -f compose.production.yaml logs -f app queue caddy

# Production status
docker compose -f compose.production.yaml ps
```
