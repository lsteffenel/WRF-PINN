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
# Volume nomme sur l'arbre WRF : avec --rm, la couche writable du conteneur est
# jettee a la sortie -> un build PINN fait dans un conteneur serait perdu.
# Le volume nomme est initialise depuis l'image au 1er montage, puis persiste :
# on build une fois (build_wrf_pinn.sh), et tous les conteneurs suivants
# retrouvent les binaires patches (main/wrf.exe avec le PINN) et les .F patches.
WRF_VOL="${WRF_VOL:-wrf-pinn-wrf}"
echo "Image: wrf-pinn:${IMAGE_TAG} | montages: ${HOST_DIR}/runs->/opt/runs, ${HOST_DIR}/data->/opt/data, ${HOST_DIR}/pinn->/opt/pinn, volume ${WRF_VOL}->/comsoftware/wrf/WRF-4.6.1"
docker run -it --rm \
  --name wrf-pinn \
  --gpus all \
  --shm-size=2g \
  --cpus=48 \
  -v "${HOST_DIR}/runs":/opt/runs \
  -v "${HOST_DIR}/data":/opt/data \
  -v "${HOST_DIR}/pinn":/opt/pinn \
  -v "${WRF_VOL}":/comsoftware/wrf/WRF-4.6.1 \
  "wrf-pinn:${IMAGE_TAG}"
