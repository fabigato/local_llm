#!/bin/bash

docker run --rm \
  -v /Users/fabigato/repos/local_llm/nginx/certbot/www:/var/www/certbot \
  -v /Users/fabigato/repos/local_llm/nginx/certbot/conf:/etc/letsencrypt \
  certbot/certbot renew \
  --non-interactive \
  --webroot -w /var/www/certbot