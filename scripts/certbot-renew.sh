#!/bin/bash
set -euo pipefail

# Resolve the repo root from this script's own location, so the absolute paths
# Docker requires work no matter where the script is checked out or what the
# working directory is (launchd runs jobs from "/").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

docker run --rm \
  -v "${REPO_ROOT}/nginx/certbot/www:/var/www/certbot" \
  -v "${REPO_ROOT}/nginx/certbot/conf:/etc/letsencrypt" \
  certbot/certbot renew \
  --non-interactive \
  --webroot -w /var/www/certbot