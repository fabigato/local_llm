#!/bin/bash
# One-time issuance of the wildcard certificate. Run this BEFORE `docker compose up`
# the first time, and again only if you change domains.
#
# Produces a single certificate covering both the apex and every subdomain:
#     DOMAIN  +  *.DOMAIN        (two SANs, one cert, one private key)
#
# Why DNS-01 and not the old webroot flow: Let's Encrypt only issues wildcards
# over DNS-01. That is also why nginx is not involved here at all — no port 80,
# no challenge file, no chicken-and-egg where nginx can't boot because the cert
# it references doesn't exist yet. certbot talks to Infomaniak's API, writes a
# _acme-challenge TXT record, and waits for it to propagate.
#
# Usage:
#   scripts/certbot-issue.sh              # real certificate
#   scripts/certbot-issue.sh --staging    # Let's Encrypt staging (untrusted, unlimited retries)
#   scripts/certbot-issue.sh --dry-run    # full challenge, no certificate written
#
# ALWAYS do a --staging or --dry-run pass first. Production issuance failures
# burn into a rate limit; staging ones don't.
set -euo pipefail

# Resolve the repo root from this script's own location, so the absolute paths
# Docker requires work no matter where the script is checked out or what the
# working directory is (launchd runs jobs from "/").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CREDENTIALS="${REPO_ROOT}/nginx/certbot/infomaniak.ini"
IMAGE="certbot-infomaniak:local"

# The certificate is named "wildcard" rather than after the domain, on purpose:
# nginx.conf declares ssl_certificate once at http level for every server block,
# and nginx.conf is mounted verbatim (no envsubst), so the path cannot contain
# ${DOMAIN}. A fixed name also keeps the real domain out of file paths.
CERT_NAME="wildcard"

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
DOMAIN="$(grep -E '^DOMAIN=' "${REPO_ROOT}/.env" 2>/dev/null | head -1 | cut -d= -f2- || true)"
if [[ -z "${DOMAIN}" ]]; then
  echo "error: DOMAIN is not set in ${REPO_ROOT}/.env (see .env.example)" >&2
  exit 1
fi

if [[ ! -f "${CREDENTIALS}" ]]; then
  echo "error: ${CREDENTIALS} not found." >&2
  echo "       cp nginx/certbot/infomaniak.ini.example nginx/certbot/infomaniak.ini" >&2
  echo "       then paste a Domain-scoped API token into it and chmod 600 it." >&2
  exit 1
fi

# certbot aborts on a group/world-readable credentials file. Fail here with a
# clearer message than certbot's.
PERMS="$(stat -f '%Lp' "${CREDENTIALS}")"
if [[ "${PERMS}" != "600" ]]; then
  echo "error: ${CREDENTIALS} has mode ${PERMS}, expected 600." >&2
  echo "       chmod 600 ${CREDENTIALS}" >&2
  exit 1
fi

read -r -p "Issue certificate for ${DOMAIN} and *.${DOMAIN}? [y/N] " REPLY
[[ "${REPLY}" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

mkdir -p "${REPO_ROOT}/nginx/certbot/conf" "${REPO_ROOT}/nginx/certbot/logs"

echo "[certbot] building ${IMAGE}"
docker build -q -t "${IMAGE}" "${REPO_ROOT}/nginx/certbot" >/dev/null

# ----------------------------------------------------------------------------
# Issue
# ----------------------------------------------------------------------------
# NOTE: the container path of the credentials file (/secrets/infomaniak.ini) is
# recorded verbatim into the renewal config, and certbot-renew.sh reuses it. If
# you change it here, change it there too or renewals will fail.
echo "[certbot] requesting ${DOMAIN} + *.${DOMAIN} (propagation wait is ~120s)"
docker run --rm \
  -v "${REPO_ROOT}/nginx/certbot/conf:/etc/letsencrypt" \
  -v "${REPO_ROOT}/nginx/certbot/logs:/var/log/letsencrypt" \
  -v "${CREDENTIALS}:/secrets/infomaniak.ini:ro" \
  "${IMAGE}" certonly \
  --non-interactive \
  --agree-tos \
  --authenticator dns-infomaniak \
  --dns-infomaniak-credentials /secrets/infomaniak.ini \
  --cert-name "${CERT_NAME}" \
  --key-type ecdsa \
  -d "${DOMAIN}" \
  -d "*.${DOMAIN}" \
  "$@"

echo
echo "[certbot] done. Certificate lives at nginx/certbot/conf/live/${CERT_NAME}/"
echo "[certbot] nginx.conf reads it from /etc/letsencrypt/live/${CERT_NAME}/ — start the stack with:"
echo "           docker compose up -d"
