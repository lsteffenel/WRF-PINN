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
# loaders de tables d'absorption (dans la partie WRF) : sw_kgb16..29, lw_kgb01..16
awk '/subroutine sw_kgb16\(/{f=1} f{print} f && /^END MODULE module_ra_rrtmg_sw/{exit}' "$SW" \
  | sed 's/wrf_dm_on_monitor/pinn_dm_on_monitor/g' > "$OUT/sw_kgb.F"
awk '/subroutine lw_kgb01\(/{f=1} f{print} f && /^END MODULE module_ra_rrtmg_lw/{exit}' "$LW" \
  | sed 's/wrf_dm_on_monitor/pinn_dm_on_monitor/g' > "$OUT/lw_kgb.F"

cat > "$OUT/pinn_dm_stub.f90" <<'EOF'
logical function pinn_dm_on_monitor()
  implicit none
  pinn_dm_on_monitor = .true.
end function pinn_dm_on_monitor
EOF

for f in rrtmg_sw_core.F rrtmg_lw_core.F sw_kgb.F lw_kgb.F pinn_dm_stub.f90; do
  [ -s "$OUT/$f" ] || { echo "ECHEC: $OUT/$f vide"; exit 1; }
done
echo "OK: sources extraites dans $OUT :"
ls -la "$OUT"/rrtmg_sw_core.F "$OUT"/rrtmg_lw_core.F "$OUT"/sw_kgb.F "$OUT"/lw_kgb.F "$OUT"/pinn_dm_stub.f90
