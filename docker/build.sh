#!/usr/bin/env bash
# Build de l'image Docker WRF-PINN
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t wrf-pinn:latest -f docker/Dockerfile \
  --build-arg BUILD_WPS=1 .
# NB: WRF_VERSION et WPS_VERSION sont definis dans le Dockerfile (source unique)
# pour eviter qu'un --build-arg obsolete ecrase la version corrigeant le bug module_dm
