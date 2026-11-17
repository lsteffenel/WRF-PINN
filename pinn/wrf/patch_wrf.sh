#!/usr/bin/env bash
# Patche les sources WRF ($WRF_HOME/phys/module_ra_rrtmg_sw.F et _lw.F) pour
# remplacer taumol_sw / taumol par le PINN (TorchScript via libpinn_torch.so) :
#  - insere les shells (pinn_shell_sw.inc / pinn_shell_lw.inc) dans les fichiers
#  - renomme taumol_sw/taumol -> *_ref (fallback si PINN_MODEL non defini)
#  - redirige les appels vers les shells + insere les precompute batch avant la
#    boucle iplon des drivers rrtmg_sw / rrtmg_lw
# Usage (dans le conteneur) : WRF_HOME=/comsoftware/wrf/WRF-4.6.1 bash /opt/pinn/wrf/patch_wrf.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
SW="$WRF_HOME/phys/module_ra_rrtmg_sw.F"
LW="$WRF_HOME/phys/module_ra_rrtmg_lw.F"
[ -f "$SW" ] || { echo "ECHEC: $SW absent"; exit 1; }
[ -f "$LW" ] || { echo "ECHEC: $LW absent"; exit 1; }
[ -f "$SW.orig" ] || cp "$SW" "$SW.orig"
[ -f "$LW.orig" ] || cp "$LW" "$LW.orig"
cp "$SW.orig" "$SW"
cp "$LW.orig" "$LW"

# ---------------- SW ----------------
# 1) insere le shell avant module rrtmg_sw_spcvmc (apres rrtmg_sw_taumol -> taumol_sw_ref dispo)
sed -i "/^      module rrtmg_sw_spcvmc/r $HERE/pinn_shell_sw.inc" "$SW"
# 2) renomme la definition de taumol_sw
sed -i -e 's/^      subroutine taumol_sw(/      subroutine taumol_sw_ref(/' \
       -e 's/^      end subroutine taumol_sw/      end subroutine taumol_sw_ref/' \
       -e 's/use rrtmg_sw_taumol, only: taumol_sw$/use rrtmg_sw_taumol, only: taumol_sw_ref/' "$SW"
# 3) la ou on use rrtmg_sw_taumol, on rend aussi le shell visible (taumol_sw -> shell)
sed -i 's/^\( *use rrtmg_sw_taumol.*\)$/\1\n      use module_pinn_shell_sw, only: taumol_sw, pinn_precompute_sw, pinn_reset_sw/' "$SW"
# 4) precompute batch + reset avant la boucle iplon du driver rrtmg_sw
sed -i 's/^      do iplon = 1, ncol$/      call pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, h2ovmr, o3vmr, co2vmr, ch4vmr, n2ovmr, o2vmr)\n      call pinn_reset_sw()\n      do iplon = 1, ncol/' "$SW"
grep -q "module module_pinn_shell_sw" "$SW" || { echo "ECHEC: shell SW non insere"; exit 1; }
grep -q "pinn_precompute_sw(ncol, nlay" "$SW" || { echo "ECHEC: precompute SW non insere"; exit 1; }
grep -q "subroutine taumol_sw_ref(" "$SW" || { echo "ECHEC: renommage taumol_sw_ref"; exit 1; }

# ---------------- LW ----------------
sed -i "/^      subroutine rrtmg_lw &/r $HERE/pinn_shell_lw.inc" "$LW"
sed -i -e 's/^      subroutine taumol(/      subroutine taumol_ref(/' \
       -e 's/^      end subroutine taumol/      end subroutine taumol_ref/' \
       -e 's/use rrtmg_lw_taumol, only: taumol$/use rrtmg_lw_taumol, only: taumol_ref/' "$LW"
sed -i 's/^\( *use rrtmg_lw_taumol.*\)$/\1\n      use module_pinn_shell_lw, only: pinn_taumol_lw, pinn_precompute_lw, pinn_reset_lw/' "$LW"
sed -i 's/call taumol(/call pinn_taumol_lw(/' "$LW"
sed -i 's/^      do iplon = 1, ncol$/      call pinn_precompute_lw(ncol, nlay, play, plev, tlay, tlev, tsfc, h2ovmr, o3vmr, co2vmr, ch4vmr, n2ovmr, o2vmr)\n      call pinn_reset_lw()\n      do iplon = 1, ncol/' "$LW"
grep -q "module module_pinn_shell_lw" "$LW" || { echo "ECHEC: shell LW non insere"; exit 1; }
grep -q "call pinn_taumol_lw(" "$LW" || { echo "ECHEC: call pinn_taumol_lw absent"; exit 1; }
grep -q "pinn_precompute_lw(ncol, nlay" "$LW" || { echo "ECHEC: precompute LW non insere"; exit 1; }
echo "OK: patch WRF applique (.orig sauvegardes a cote)"
