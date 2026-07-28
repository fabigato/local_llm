#!/bin/bash
# Renew every certificate that is within 30 days of expiry, then reload nginx if
# anything actually changed. Driven by launchd every 12h (see
# com.certbot.docker.renew.plist); safe and near-free to run when nothing is due.
#
# ONE JOB HANDLES ALL CERTIFICATES. `certbot renew` is not per-certificate: it
# walks every file in /etc/letsencrypt/renewal/ and renews the ones that need it,
# each using the authenticator recorded in ITS OWN renewal config. So a DNS-01
# wildcard and a leftover HTTP-01 cert renew correctly in the same run, and you
# never need a second launchd job.
#
# THAT IS ALSO WHY NO AUTHENTICATOR FLAGS APPEAR BELOW. The old version of this
# script passed `--webroot -w /var/www/certbot`, which OVERRIDES the stored
# authenticator for every certificate in the run. Passing it now would force
# HTTP-01 onto the wildcard cert, which Let's Encrypt cannot validate that way,
# and renewal would fail. Keep this command bare.
set -euo pipefail

# Resolve the repo root from this script's own location, so the absolute paths
# Docker requires work no matter where the script is checked out or what the
# working directory is (launchd runs jobs from "/").
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CREDENTIALS="${REPO_ROOT}/nginx/certbot/infomaniak.ini"
IMAGE="certbot-infomaniak:local"

# Sentinel touched by the deploy hook below, which runs INSIDE the container only
# when a certificate was actually replaced. We check for it out here, on the host,
# because that's the only place with a docker client to reload nginx with.
#
# This replaces the old renewal-hooks/deploy/reload-nginx.sh, which ran
# `docker exec nginx ...` inside the certbot container — where there is no docker
# binary and no docker socket. It failed silently on every renewal, leaving nginx
# serving the certificate it loaded at startup until the stack was restarted.
RENEWED_FLAG="${REPO_ROOT}/nginx/certbot/conf/.renewed"

rm -f "${RENEWED_FLAG}"
mkdir -p "${REPO_ROOT}/nginx/certbot/logs"

docker build -q -t "${IMAGE}" "${REPO_ROOT}/nginx/certbot" >/dev/null

# The credentials path must match the one certbot-issue.sh used: certbot recorded
# it verbatim in the renewal config and reads it back from there on every renew.
docker run --rm \
  -v "${REPO_ROOT}/nginx/certbot/conf:/etc/letsencrypt" \
  -v "${REPO_ROOT}/nginx/certbot/logs:/var/log/letsencrypt" \
  -v "${CREDENTIALS}:/secrets/infomaniak.ini:ro" \
  "${IMAGE}" renew \
  --non-interactive \
  --deploy-hook 'touch /etc/letsencrypt/.renewed'

if [[ -f "${RENEWED_FLAG}" ]]; then
  rm -f "${RENEWED_FLAG}"
  if docker ps --format '{{.Names}}' | grep -qx nginx; then
    echo "[certbot] certificate renewed -> reloading nginx"
    docker exec nginx nginx -s reload
  else
    echo "[certbot] certificate renewed, but the nginx container isn't running;" \
         "it will pick up the new cert on next start"
  fi
else
  echo "[certbot] nothing was due for renewal"
fi
