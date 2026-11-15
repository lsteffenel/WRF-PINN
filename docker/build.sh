#!/usr/bin/env bash
# Build de l'image Docker WRF-PINN
# Usage: docker/build.sh [gprof]
#   (defaut) -> wrf-pinn:latest
#   gprof    -> wrf-pinn:gprof  (WRF recompile avec -pg : main/wrf.exe.gprof + main/ideal.exe.gprof)
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=wrf-pinn:latest
EXTRA_ARGS=""
if [ "${1:-}" = "gprof" ]; then
  TAG=wrf-pinn:gprof
  EXTRA_ARGS="--build-arg BUILD_GPROF=1"
fi
# shellcheck disable=SC2086
docker build -t "$TAG" -f docker/Dockerfile \
  --build-arg BUILD_WPS=1 $EXTRA_ARGS .
# NB: WRF_VERSION et WPS_VERSION sont definis dans le Dockerfile (source unique)
# pour eviter qu'un --build-arg obsolete ecrase la version corrigeant le bug module_dm
