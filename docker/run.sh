#!/usr/bin/env bash
# Lancement du conteneur WRF avec les données montées depuis /mnt/2ToDisk
# --gpus all : accès aux GPUs de l'hôte (nvidia-container-toolkit requis,
# cf. docs/INSTALL.md) pour l'entraînement PyTorch du PINN
# Usage: docker/run.sh [repertoire-de-travail-sur-hote] [tag-image]
#   defaut : wrf-pinn:latest ; ex. gprof : docker/run.sh . gprof -> wrf-pinn:gprof
#   (image construite par 'docker/build.sh gprof', binaires WRF avec -pg)
set -euo pipefail
HOST_DIR="${1:-/mnt/2ToDisk/WRF-PINN}"
IMAGE_TAG="${2:-latest}"
mkdir -p "${HOST_DIR}/runs" "${HOST_DIR}/data"
echo "Image: wrf-pinn:${IMAGE_TAG} | montages: ${HOST_DIR}/runs->/opt/runs, ${HOST_DIR}/data->/opt/data"
docker run -it --rm \
  --name wrf-pinn \
  --gpus all \
  --shm-size=2g \
  --cpus=48 \
  -v "${HOST_DIR}/runs":/opt/runs \
  -v "${HOST_DIR}/data":/opt/data \
  "wrf-pinn:${IMAGE_TAG}"
