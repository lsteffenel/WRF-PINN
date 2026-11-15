#!/usr/bin/env bash
# Profilage de la part radiation RRTMG (objectif du projet, cf. docs/CONTEXTE.md §5.1)
# sur le domaine idealise em_quarter_ss (42x42x41, 60 min) :
#   ideal.exe une fois, puis deux runs wrf.exe :
#     - rad_on  : ra_lw_physics=4, ra_sw_physics=4 (RRTMG LW/SW), radt=10 min
#     - rad_off : ra_lw_physics=0, ra_sw_physics=0
# Comparer ensuite "Timing for main ... on domain 1" dans out/rsl.out.0000 de chaque run.
# Usage (dans le conteneur) : bash /opt/runs/cases/rrtmg_on_off/run.sh
# Env : NP (rangs MPI, defaut 8), RUNS_ROOT (defaut /opt/runs), WRF_HOME (defaut /comsoftware/wrf/WRF-4.6.1)
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="${RUNS_ROOT:-/opt/runs}"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
NP="${NP:-8}"
BASE="$RUNS_ROOT/cases/rrtmg_on_off/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BASE"
cd "$BASE"
ln -sf "$WRF_HOME/main/ideal.exe" "$WRF_HOME/main/wrf.exe" .
# -x est faux sur un lien symbolique mort : on detecte un binaire absent
[ -x ./ideal.exe ] || { echo "ECHEC: $WRF_HOME/main/ideal.exe absent (image compilee sans la cible idealisee em_quarter_ss) - reconstruire l'image"; exit 1; }
[ -x ./wrf.exe ]   || { echo "ECHEC: $WRF_HOME/main/wrf.exe absent"; exit 1; }
cp "$WRF_HOME/test/em_quarter_ss/input_sounding" .
cp "$CASE_DIR/namelist.input.rad_on" namelist.input
./ideal.exe > ideal.log 2>&1   # produit wrfinput_d01 (+ wrfbdy_d01)
for v in rad_on rad_off; do
  W="$BASE/$v"
  mkdir -p "$W"
  cd "$W"
  ln -sf "$WRF_HOME/main/wrf.exe" .
  cp "$BASE"/wrfinput_d01 . 2>/dev/null || true
  cp "$BASE"/wrfbdy_d01   . 2>/dev/null || true
  cp "$CASE_DIR/namelist.input.$v" namelist.input
  # wrf.exe lit les fichiers de donnees DANS LE CWD : avec la radiation RRTMG
  # active (ra_lw/sw_physics=4), il faut RRTMG_LW_DATA, RRTMG_SW_DATA, ozone*,
  # aerosol*, *.TBL... -> liens depuis $WRF_HOME/run (hors namelist.input/exes)
  for f in "$WRF_HOME"/run/*; do
    b="$(basename "$f")"
    case "$b" in namelist.input|*.exe|README*) continue ;; esac
    ln -sf "$f" "$b"
  done
  # conteneur en root : OpenMPI exige --allow-run-as-root
  mpirun --allow-run-as-root -np "$NP" ./wrf.exe > "wrf.$v.log" 2>&1
  mkdir -p out
  mv -f rsl.* wrfout* out/ 2>/dev/null || true
done
echo "OK: runs termines dans $BASE"
echo "== Timing for main (rsl.out.0000) =="
for v in rad_on rad_off; do
  echo "-- $v"
  grep -m1 "Timing for main" "$BASE/$v/out/rsl.out.0000" || true
done
