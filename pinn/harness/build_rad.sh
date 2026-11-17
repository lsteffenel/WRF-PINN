#!/usr/bin/env bash
# Compile DEUX bibliotheques de transfert radiatif complet (clear-sky) :
#   build/rad_ref/librrtmg_rad_ref.so   : taumol_sw reel (reference)
#   build/rad_pinn/librrtmg_rad_pinn.so : taumol_sw remplace par pinn_taumol_shell
#                                         (taug/taur injectes depuis Python = PINN)
# + wrapper pinn_rad_api.f90 (pinn_rad_init / pinn_sw_rad / pinn_lw_rad).
# A lancer DANS le conteneur wrf-pinn, apres build.sh :
#   bash /opt/pinn/harness/build_rad.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"

GFORTRAN_FLAGS="-cpp -ffree-form -ffree-line-length-none -O2 -fPIC -shared"

build_variant () {
  local variant="$1"
  local B="$HERE/build/rad_$variant"
  mkdir -p "$B"
  bash "$HERE/extract_sources.sh" "$B"
  python3 "$HERE/convert_rrtmg_data.py" "$WRF_HOME/run/RRTMG_SW_DATA" "$B/RRTMG_SW_DATA.le"
  python3 "$HERE/convert_rrtmg_data.py" "$WRF_HOME/run/RRTMG_LW_DATA" "$B/RRTMG_LW_DATA.le"
  if [ "$variant" = "pinn" ]; then
    # renomme la DEFINITION de taumol_sw (le call taumol_sw de spcvmc_sw restera
    # et sera resolu vers le shell via le use ajoute ci-dessous)
    sed -i -e 's/^      subroutine taumol_sw(/      subroutine taumol_sw_ref(/' \
           -e 's/^      end subroutine taumol_sw/      end subroutine taumol_sw_ref/' \
           "$B/rrtmg_sw_core.F"
    sed -i 's/^\( *use rrtmg_sw_taumol.*\)$/\1\n      use pinn_taumol_shell, only: taumol_sw/' \
           "$B/rrtmg_sw_core.F"
  fi
  cd "$B"
  local srcs="pinn_dm_stub.f90 rrtmg_lw_core.F"
  if [ "$variant" = "pinn" ]; then
    srcs="$srcs $HERE/pinn_taumol_shell.f90 rrtmg_sw_core.F"
  else
    srcs="$srcs rrtmg_sw_core.F"
  fi
  srcs="$srcs sw_kgb.F lw_kgb.F $HERE/pinn_rad_api.f90"
  gfortran $GFORTRAN_FLAGS -J "$B" -o "$B/librrtmg_rad_$variant.so" $srcs
  echo "OK: $B/librrtmg_rad_$variant.so"
  nm -D "$B/librrtmg_rad_$variant.so" | grep -E "pinn_(rad_init|sw_rad|lw_rad)" || true
}

build_variant ref
build_variant pinn
