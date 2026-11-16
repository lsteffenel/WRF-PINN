#!/usr/bin/env bash
# Compile la bibliotheque librrtmg_taumol.so (wrapper C de taumol_sw / taumol).
# A lancer DANS le conteneur wrf-pinn (gfortran + sources WRF presents) :
#   WRF_HOME=/comsoftware/wrf/WRF-4.6.1 bash /opt/pinn/harness/build.sh [builddir]
# ou en local depuis la racine du depot monte dans le conteneur.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
BUILD="${1:-$HERE/build}"
mkdir -p "$BUILD"
bash "$HERE/extract_sources.sh" "$BUILD"
cd "$BUILD"
# -cpp : les .F de WRF passent par le preproc ; -ffree-form OBLIGATOIRE :
# gfortran traite .F en fixed-form par defaut (WRF passe -ffree-form dans configure.wrf)
# -J : repertoire des .mod
gfortran -cpp -ffree-form -ffree-line-length-none -O2 -fPIC -shared \
  -J "$BUILD" \
  -o "$BUILD/librrtmg_taumol.so" \
  pinn_dm_stub.f90 rrtmg_lw_core.F rrtmg_sw_core.F sw_kgb.F lw_kgb.F \
  "$HERE/pinn_taumol_api.f90"
echo "OK: $BUILD/librrtmg_taumol.so"
nm -D "$BUILD/librrtmg_taumol.so" | grep -E "pinn_(sw|lw)_(init|taumol)" || true
