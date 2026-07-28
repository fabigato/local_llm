# certbot + the Infomaniak DNS authenticator.
#
# The stock certbot/certbot image ships only the HTTP-01 authenticators
# (webroot, standalone), and Let's Encrypt will not issue a WILDCARD cert over
# HTTP-01 — wildcards are DNS-01 only. So we bake in Infomaniak's plugin, which
# proves domain control by writing a _acme-challenge TXT record via their API.
#
# There is no official certbot/dns-infomaniak image (unlike dns-cloudflare etc.),
# hence this two-line build. Built automatically by scripts/certbot-issue.sh and
# scripts/certbot-renew.sh; you never need to run `docker build` by hand.
FROM certbot/certbot:latest

RUN pip install --no-cache-dir certbot-dns-infomaniak
