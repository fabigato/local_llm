#!/bin/bash

echo "[certbot] certificate renewed → reloading nginx"

docker exec nginx nginx -s reload