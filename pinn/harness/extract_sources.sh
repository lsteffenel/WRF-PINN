#!/usr/bin/env bash
# Extrait des sources WRF (RRTMG SW/LW) les modules "core" standalone :
# tout ce qui est AVANT les modules WRF (module_ra_rrtmg_sw / module_ra_rrtmg_lw),
# plus les loaders de tables sw_kgb16..29 / lw_kgb01..16 (dans la partie WRF, avec
# wrf_dm_on_monitor remplace par un stub local).
# A lancer DANS le conteneur (ou la ou WRF_HOME est present).
# Usage: WRF_HOME=/comsoftware/wrf/WRF-4.6.1 bash extract_sources.sh [outdir]
set -euo pipefail
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
OUT="${1:-.}"
SW="$WRF_HOME/phys/module_ra_rrtmg_sw.F"
LW="$WRF_HOME/phys/module_ra_rrtmg_lw.F"
[ -f "$SW" ] || { echo "ECHEC: $SW absent (WRF_HOME=$WRF_HOME ?)"; exit 1; }
[ -f "$LW" ] || { echo "ECHEC: $LW absent (WRF_HOME=$WRF_HOME ?)"; exit 1; }
mkdir -p "$OUT"

# core SW : parrrsw, rrsw_*, rrtmg_sw_{reftra,setcoef,taumol,init,vrtqdr,spcvmc,rad}
awk '/^MODULE module_ra_rrtmg_sw/{exit} {print}' "$SW" > "$OUT/rrtmg_sw_core.F"
# core LW : parkind, parrrtm, rrlw_*, mcica_*, rrtmg_lw_*
awk '/^MODULE module_ra_rrtmg_lw/{exit} {print}' "$LW" > "$OUT/rrtmg_lw_core.F"
# loaders de tables d'absorption (dans la partie WRF) : sw_kgb16..29, lw_kgb01..16.
# - on exclut la ligne "END MODULE ..." (sinon gfortran: Expecting END PROGRAM)
# - wrf_dm_on_monitor -> stub local (le read n'est fait qu'au "monitor" = ici toujours)
# - DM_BCAST_MACRO(...) est un #define WRF (module_dm) -> on le supprime (bcast inutile
#   en standalone mono-processus ; le read juste avant a deja charge les tables)
# loaders de tables d'absorption : on extrait CHAQUE bloc 'subroutine sw_kgbNN /
# lw_kgbNN ... end subroutine' individuellement (sinon on embarque aussi le reste
# du module WRF -> symboles externes genre retab_ au dlopen)
awk '/subroutine sw_kgb[0-9]+\(/{f=1} f{print} f && /^[[:space:]]*end subroutine/{f=0}' "$SW" \
  | sed -e 's/wrf_dm_on_monitor/pinn_dm_on_monitor/g' \
        -e 's/DM_BCAST_[A-Z_]*[[:space:]]*([^)]*)/ /g' \
        -e '/^#define/d' > "$OUT/sw_kgb.F"
awk '/subroutine lw_kgb[0-9]+\(/{f=1} f{print} f && /^[[:space:]]*end subroutine/{f=0}' "$LW" \
  | sed -e 's/wrf_dm_on_monitor/pinn_dm_on_monitor/g' \
        -e 's/DM_BCAST_[A-Z_]*[[:space:]]*([^)]*)/ /g' \
        -e '/^#define/d' > "$OUT/lw_kgb.F"
grep -c "^subroutine\|^      subroutine" "$OUT/sw_kgb.F" | xargs echo "sw_kgb: nb subroutines extraites (attendu 14):"
grep -c "^subroutine\|^      subroutine" "$OUT/lw_kgb.F" | xargs echo "lw_kgb: nb subroutines extraites (attendu 16):"
grep -q "use module_ra\|retab" "$OUT/sw_kgb.F" "$OUT/lw_kgb.F" && { echo "ECHEC: refs WRF residuelles dans les kgb"; exit 1; } || echo "OK: 0 ref module_ra/retab dans les kgb"

# stubs des symboles WRF references par les sources extraites (core + kgb) :
# - pinn_dm_on_monitor : le "monitor" standalone lit toujours les donnees
# - wrf_error_fatal : stop propre (resout tous les 'call wrf_error_fatal' restants)
cat > "$OUT/pinn_dm_stub.f90" <<'EOF'
logical function pinn_dm_on_monitor()
  implicit none
  pinn_dm_on_monitor = .true.
end function pinn_dm_on_monitor

subroutine wrf_error_fatal(msg)
  implicit none
  character(len=*), intent(in) :: msg
  print *, 'FATAL: ', msg
  stop 1
end subroutine wrf_error_fatal
EOF

for f in rrtmg_sw_core.F rrtmg_lw_core.F sw_kgb.F lw_kgb.F pinn_dm_stub.f90; do
  [ -s "$OUT/$f" ] || { echo "ECHEC: $OUT/$f vide"; exit 1; }
done
echo "OK: sources extraites dans $OUT :"
ls -la "$OUT"/rrtmg_sw_core.F "$OUT"/rrtmg_lw_core.F "$OUT"/sw_kgb.F "$OUT"/lw_kgb.F "$OUT"/pinn_dm_stub.f90
