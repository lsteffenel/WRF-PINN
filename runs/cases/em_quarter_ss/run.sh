#!/usr/bin/env bash
# Smoke test du conteneur WRF : cas idealise em_quarter_ss (livre avec WRF 4.6.1,
# 42x42x41, dx=2000 m, 60 min, radiation OFF). Aucune donnee WPS_GEOG requise.
# Usage (dans le conteneur) : bash /opt/runs/cases/em_quarter_ss/run.sh
# Env : NP (rangs MPI, defaut 8), RUNS_ROOT (defaut /opt/runs), WRF_HOME (defaut /comsoftware/wrf/WRF-4.6.1)
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="${RUNS_ROOT:-/opt/runs}"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
NP="${NP:-8}"
WORK="$RUNS_ROOT/cases/em_quarter_ss/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
cd "$WORK"
ln -sf "$WRF_HOME/main/ideal.exe" "$WRF_HOME/main/wrf.exe" .
cp "$WRF_HOME/test/em_quarter_ss/input_sounding" .
cp "$CASE_DIR/namelist.input" .
./ideal.exe > ideal.log 2>&1
# conteneur en root : OpenMPI exige --allow-run-as-root
mpirun --allow-run-as-root -np "$NP" ./wrf.exe > wrf.log 2>&1
mkdir -p out
mv -f rsl.* wrfout* out/ 2>/dev/null || true
echo "OK: run termine dans $WORK"
grep -m1 "Timing for main" out/rsl.out.0000 || true
