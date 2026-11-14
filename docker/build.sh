#!/usr/bin/env bash
# Build de l'image Docker WRF-PINN
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t wrf-pinn:latest -f docker/Dockerfile \
  --build-arg WRF_VERSION=v4.6.0 \
  --build-arg BUILD_WPS=1 .
