#!/usr/bin/env bash
# Lancement du conteneur WRF avec les données montées depuis /mnt/2ToDisk
# Usage: docker/run.sh [repertoire-de-travail-sur-hote]
set -euo pipefail
HOST_DIR="${1:-/mnt/2ToDisk/WRF-PINN}"
mkdir -p "${HOST_DIR}/runs" "${HOST_DIR}/data"
docker run -it --rm \
  --name wrf-pinn \
  --shm-size=2g \
  --cpus=48 \
  -v "${HOST_DIR}/runs":/opt/runs \
  -v "${HOST_DIR}/data":/opt/data \
  wrf-pinn:latest
