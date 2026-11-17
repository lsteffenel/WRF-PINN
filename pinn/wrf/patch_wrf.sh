#!/usr/bin/env bash
# Patche les sources WRF (module_ra_rrtmg_sw.F / _lw.F) pour remplacer
# taumol_sw / taumol par le PINN (TorchScript via libpinn_torch.so).
#
# REGLES CRITIQUES (bugs corriges) :
#  1) les shells (.inc) contiennent un module COMPLET -> insertion AVANT une
#     ligne "module ..." de premier niveau, JAMAIS apres (sed 'r' insere APRES
#     l'ancre -> module imbrique -> libwrflib.a incomplet -> undefined reference
#     au link final de ideal.exe/wrf.exe).
#     - SW: avant "module rrtmg_sw_spcvmc" ; LW: avant "module rrtmg_lw_rad".
#  2) les "use module_pinn_shell_*" sont ajoutes AVANT l'insertion du shell,
#     avec des ancres exactes ($) : sinon use circulaire dans le shell lui-meme.
#  3) WRF appelle rrtmg_sw / rrtmg_lw COLONNE PAR COLONNE (ncol=1, boucles
#     j_loop/i_loop dans les wrappers RRTMG_SWRAD / RRTMG_LWRAD) : le precompute
#     batch est donc place au niveau WRAPPER (toute la tuile d'un coup, avant
#     j_loop), PAS dans le driver rrtmg_sw/lw. L'ordre d'enumeration du batch
#     (j externe, i interne) = l'ordre des appels per-column -> le compteur
#     pinn_*_col dans le shell reste aligne avec le batch.
#  4) renommage taumol_sw/taumol -> *_ref (fallback si PINN_MODEL non defini)
# Usage : WRF_HOME=/comsoftware/wrf/WRF-4.6.1 bash /opt/pinn/wrf/patch_wrf.sh
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
# 3) shell (module complet) AVANT module rrtmg_sw_spcvmc (top-level)
insert_before "$SW" '^ *module rrtmg_sw_spcvmc *$' "$HERE/pinn_shell_sw.inc"
# 4) wrapper RRTMG_SWRAD : use du shell (apres son IMPLICIT NONE) ...
awk '
  /SUBROUTINE RRTMG_SWRAD/ {inw=1}
  inw && /IMPLICIT NONE/ && !done {print; print "   USE module_pinn_shell_sw, ONLY : pinn_precompute_sw_tile"; done=1; inw=0; next}
  {print}
' "$SW" > "$SW.tmp" && mv "$SW.tmp" "$SW"
# 5) ... et precompute batch de la tuile AVANT la boucle j du wrapper
awk -v call='      call pinn_precompute_sw_tile(its, ite, jts, jte, kts, kte, nlayers, p3d, p8w, t3d, t8w, qv3d, o33d, tsk, yr)' '
  /j_loop: do j = jts,jte/ && !done {print call; done=1}
  {print}
' "$SW" > "$SW.tmp" && mv "$SW.tmp" "$SW"

# verifs SW
[ "$(grep -c '^ *module module_pinn_shell_sw' "$SW")" = "1" ] || { echo "ECHEC: shell SW non insere (ou multiple)"; exit 1; }
grep -A3 '^ *end module module_pinn_shell_sw' "$SW" | grep -q 'module rrtmg_sw_spcvmc' || { echo "ECHEC: shell SW pas juste avant rrtmg_sw_spcvmc"; exit 1; }
if awk '/^ *module module_pinn_shell_sw/,/^ *end module module_pinn_shell_sw/' "$SW" | grep -q 'use module_pinn_shell_sw'; then
  echo "ECHEC: use circulaire dans le shell SW"; exit 1
fi
grep -q 'subroutine taumol_sw_ref(' "$SW" || { echo "ECHEC: renommage taumol_sw_ref"; exit 1; }
grep -q 'use rrtmg_sw_taumol, only: taumol_sw_ref' "$SW" || { echo "ECHEC: use taumol_sw_ref (spcvmc)"; exit 1; }
grep -q 'use module_pinn_shell_sw, only: taumol_sw$' "$SW" || { echo "ECHEC: use shell taumol_sw (spcvmc)"; exit 1; }
grep -q 'USE module_pinn_shell_sw, ONLY : pinn_precompute_sw_tile' "$SW" || { echo "ECHEC: use shell tile (wrapper SWRAD)"; exit 1; }
grep -q 'call pinn_precompute_sw_tile(its, ite, jts, jte' "$SW" || { echo "ECHEC: precompute tile SW non insere (wrapper)"; exit 1; }
[ "$(grep -c 'j_loop: do j = jts,jte' "$SW")" = "1" ] || { echo "ECHEC: j_loop SW perdue"; exit 1; }
grep -q 'call pinn_precompute_sw(ncol, nlay' "$SW" && { echo "ECHEC: vieux precompute driver encore la"; exit 1; } || true

# ---------------- LW ----------------
sed -i -e 's/^      subroutine taumol(/      subroutine taumol_ref(/' \
       -e 's/^      end subroutine taumol/      end subroutine taumol_ref/' "$LW"
sed -i 's/^      use rrtmg_lw_taumol, only: taumol$/      use rrtmg_lw_taumol, only: taumol_ref\n      use module_pinn_shell_lw, only: pinn_taumol_lw/' "$LW"
sed -i 's/call taumol(/call pinn_taumol_lw(/' "$LW"
insert_before "$LW" '^ *module rrtmg_lw_rad *$' "$HERE/pinn_shell_lw.inc"
awk '
  /SUBROUTINE RRTMG_LWRAD/ {inw=1}
  inw && /IMPLICIT NONE/ && !done {print; print "   USE module_pinn_shell_lw, ONLY : pinn_precompute_lw_tile"; done=1; inw=0; next}
  {print}
' "$LW" > "$LW.tmp" && mv "$LW.tmp" "$LW"
awk -v call='      call pinn_precompute_lw_tile(its, ite, jts, jte, kts, kte, nlayers, p3d, p8w, t3d, t8w, qv3d, o33d, tsk, yr)' '
  /j_loop: do j = jts,jte/ && !done {print call; done=1}
  {print}
' "$LW" > "$LW.tmp" && mv "$LW.tmp" "$LW"

# verifs LW
[ "$(grep -c '^ *module module_pinn_shell_lw' "$LW")" = "1" ] || { echo "ECHEC: shell LW non insere (ou multiple)"; exit 1; }
grep -A3 '^ *end module module_pinn_shell_lw' "$LW" | grep -q 'module rrtmg_lw_rad' || { echo "ECHEC: shell LW pas juste avant rrtmg_lw_rad"; exit 1; }
if awk '/^ *module module_pinn_shell_lw/,/^ *end module module_pinn_shell_lw/' "$LW" | grep -q 'use module_pinn_shell_lw'; then
  echo "ECHEC: use circulaire dans le shell LW"; exit 1
fi
grep -q 'subroutine taumol_ref(' "$LW" || { echo "ECHEC: renommage taumol_ref"; exit 1; }
grep -q 'use rrtmg_lw_taumol, only: taumol_ref' "$LW" || { echo "ECHEC: use taumol_ref (driver)"; exit 1; }
grep -q 'use module_pinn_shell_lw, only: pinn_taumol_lw' "$LW" || { echo "ECHEC: use shell LW (driver)"; exit 1; }
grep -q 'call pinn_taumol_lw(' "$LW" || { echo "ECHEC: call pinn_taumol_lw absent"; exit 1; }
grep -q 'USE module_pinn_shell_lw, ONLY : pinn_precompute_lw_tile' "$LW" || { echo "ECHEC: use shell tile (wrapper LWRAD)"; exit 1; }
grep -q 'call pinn_precompute_lw_tile(its, ite, jts, jte' "$LW" || { echo "ECHEC: precompute tile LW non insere (wrapper)"; exit 1; }
[ "$(grep -c 'j_loop: do j = jts,jte' "$LW")" = "1" ] || { echo "ECHEC: j_loop LW perdue"; exit 1; }
echo "OK: patch WRF applique (.orig sauvegardes a cote)"
