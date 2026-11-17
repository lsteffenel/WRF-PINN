#!/usr/bin/env bash
# Patche les sources WRF ($WRF_HOME/phys/module_ra_rrtmg_sw.F et _lw.F) pour
# remplacer taumol_sw / taumol par le PINN (TorchScript via libpinn_torch.so).
#
# REGLES CRITIQUES (bugs corriges ici) :
#  1) les shells (.inc) contiennent un module COMPLET -> insertion AVANT une
#     ligne "module ..." de premier niveau, JAMAIS apres (sed 'r' insere APRES
#     l'ancre -> module imbrique -> erreur Fortran -> libwrflib.a incomplet ->
#     "undefined reference" au link final de ideal.exe/wrf.exe).
#     - SW: avant "module rrtmg_sw_spcvmc" (top-level, ~ligne 8168)
#     - LW: avant "module rrtmg_lw_rad" (7 espaces, ~ligne 10621). L'ancien
#       ancrage "subroutine rrtmg_lw &" etait DANS le module rrtmg_lw_rad.
#  2) les "use module_pinn_shell_*" sont ajoutes AVANT l'insertion du shell,
#     avec des ancres exactes ($) : sinon le sed generique matcherait aussi la
#     ligne "use rrtmg_*_taumol" du shell lui-meme -> use circulaire.
#  3) le driver SW (module rrtmg_sw_rad) n'a pas de "use rrtmg_sw_taumol" :
#     il faut lui ajouter explicitement "use module_pinn_shell_sw" pour
#     pinn_precompute_sw/pinn_reset_sw (sinon symbole non resolu a la compile).
#  4) renommage taumol_sw/taumol -> *_ref (fallback si PINN_MODEL non defini)
#  5) precompute batch + reset avant la boucle "do iplon = 1, ncol" des drivers
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

# insere le contenu de $3 AVANT la premiere ligne de $1 matchant la regex $2
insert_before() { # $1=fichier  $2=ancre-regex  $3=fichier-inc
  awk -v f="$3" -v pat="$2" '
    !done && $0 ~ pat { while ((getline line < f) > 0) print line; close(f); done=1 }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---------------- SW ----------------
# 1) renomme la definition de taumol_sw -> taumol_sw_ref
sed -i -e 's/^      subroutine taumol_sw(/      subroutine taumol_sw_ref(/' \
       -e 's/^      end subroutine taumol_sw/      end subroutine taumol_sw_ref/' "$SW"
# 2) spcvmc (seul module qui use rrtmg_sw_taumol) : taumol_sw_ref + shell taumol_sw
sed -i 's/^      use rrtmg_sw_taumol, only: taumol_sw$/      use rrtmg_sw_taumol, only: taumol_sw_ref\n      use module_pinn_shell_sw, only: taumol_sw/' "$SW"
# 3) driver rrtmg_sw_rad : precompute/reset visibles
sed -i 's/^      use rrtmg_sw_spcvmc, only: spcvmc_sw$/      use rrtmg_sw_spcvmc, only: spcvmc_sw\n      use module_pinn_shell_sw, only: pinn_precompute_sw, pinn_reset_sw/' "$SW"
# 4) shell (module complet) AVANT module rrtmg_sw_spcvmc (top-level)
insert_before "$SW" '^ *module rrtmg_sw_spcvmc *$' "$HERE/pinn_shell_sw.inc"
# 5) precompute batch + reset avant la boucle iplon du driver
sed -i 's/^      do iplon = 1, ncol$/      call pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, h2ovmr, o3vmr, co2vmr, ch4vmr, n2ovmr, o2vmr)\n      call pinn_reset_sw()\n      do iplon = 1, ncol/' "$SW"

# verifs SW
[ "$(grep -c '^ *module module_pinn_shell_sw' "$SW")" = "1" ] || { echo "ECHEC: shell SW non insere (ou multiple)"; exit 1; }
grep -A3 '^ *end module module_pinn_shell_sw' "$SW" | grep -q 'module rrtmg_sw_spcvmc' || { echo "ECHEC: shell SW pas juste avant rrtmg_sw_spcvmc"; exit 1; }
if awk '/^ *module module_pinn_shell_sw/,/^ *end module module_pinn_shell_sw/' "$SW" | grep -q 'use module_pinn_shell_sw'; then
  echo "ECHEC: use circulaire dans le shell SW"; exit 1
fi
grep -q 'subroutine taumol_sw_ref(' "$SW" || { echo "ECHEC: renommage taumol_sw_ref"; exit 1; }
grep -q 'use rrtmg_sw_taumol, only: taumol_sw_ref' "$SW" || { echo "ECHEC: use taumol_sw_ref (spcvmc)"; exit 1; }
grep -q 'use module_pinn_shell_sw, only: taumol_sw$' "$SW" || { echo "ECHEC: use shell taumol_sw (spcvmc)"; exit 1; }
grep -q 'use module_pinn_shell_sw, only: pinn_precompute_sw, pinn_reset_sw' "$SW" || { echo "ECHEC: use shell precompute (driver)"; exit 1; }
grep -q 'call pinn_precompute_sw(ncol, nlay' "$SW" || { echo "ECHEC: precompute SW non insere"; exit 1; }
[ "$(grep -c '^      do iplon = 1, ncol$' "$SW")" = "1" ] || { echo "ECHEC: boucle iplon SW perdue"; exit 1; }

# ---------------- LW ----------------
# 1) renomme la definition de taumol -> taumol_ref
sed -i -e 's/^      subroutine taumol(/      subroutine taumol_ref(/' \
       -e 's/^      end subroutine taumol/      end subroutine taumol_ref/' "$LW"
# 2) driver rrtmg_lw_rad : taumol_ref + shell (pinn_taumol_lw/precompute/reset)
sed -i 's/^      use rrtmg_lw_taumol, only: taumol$/      use rrtmg_lw_taumol, only: taumol_ref\n      use module_pinn_shell_lw, only: pinn_taumol_lw, pinn_precompute_lw, pinn_reset_lw/' "$LW"
# 3) remplace l'appel par colonne par le shell
sed -i 's/call taumol(/call pinn_taumol_lw(/' "$LW"
# 4) shell (module complet) AVANT module rrtmg_lw_rad (top-level, 7 espaces)
insert_before "$LW" '^ *module rrtmg_lw_rad *$' "$HERE/pinn_shell_lw.inc"
# 5) precompute batch + reset avant la boucle iplon du driver
sed -i 's/^      do iplon = 1, ncol$/      call pinn_precompute_lw(ncol, nlay, play, plev, tlay, tlev, tsfc, h2ovmr, o3vmr, co2vmr, ch4vmr, n2ovmr, o2vmr)\n      call pinn_reset_lw()\n      do iplon = 1, ncol/' "$LW"

# verifs LW
[ "$(grep -c '^ *module module_pinn_shell_lw' "$LW")" = "1" ] || { echo "ECHEC: shell LW non insere (ou multiple)"; exit 1; }
grep -A3 '^ *end module module_pinn_shell_lw' "$LW" | grep -q 'module rrtmg_lw_rad' || { echo "ECHEC: shell LW pas juste avant rrtmg_lw_rad"; exit 1; }
if awk '/^ *module module_pinn_shell_lw/,/^ *end module module_pinn_shell_lw/' "$LW" | grep -q 'use module_pinn_shell_lw'; then
  echo "ECHEC: use circulaire dans le shell LW"; exit 1
fi
grep -q 'subroutine taumol_ref(' "$LW" || { echo "ECHEC: renommage taumol_ref"; exit 1; }
grep -q 'use rrtmg_lw_taumol, only: taumol_ref' "$LW" || { echo "ECHEC: use taumol_ref (driver)"; exit 1; }
grep -q 'use module_pinn_shell_lw, only: pinn_taumol_lw, pinn_precompute_lw, pinn_reset_lw' "$LW" || { echo "ECHEC: use shell LW (driver)"; exit 1; }
grep -q 'call pinn_taumol_lw(' "$LW" || { echo "ECHEC: call pinn_taumol_lw absent"; exit 1; }
grep -q 'call pinn_precompute_lw(ncol, nlay' "$LW" || { echo "ECHEC: precompute LW non insere"; exit 1; }
[ "$(grep -c '^      do iplon = 1, ncol$' "$LW")" = "1" ] || { echo "ECHEC: boucle iplon LW perdue"; exit 1; }
echo "OK: patch WRF applique (.orig sauvegardes a cote)"
