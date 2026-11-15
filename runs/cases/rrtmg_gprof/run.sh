#!/usr/bin/env bash
# Profilage fin gprof du cas rrtmg (radiation RRTMG ON) avec l'image wrf-pinn:gprof :
# binaires construits avec -pg (main/wrf.exe.gprof, main/ideal.exe.gprof).
# Produit out/gprof.txt (flat profile complet) et en extrait les lignes taumol/rrtmg.
# A lancer dans le conteneur wrf-pinn:gprof : docker run ... wrf-pinn:gprof
# Usage : bash /opt/runs/cases/rrtmg_gprof/run.sh
# Env : NP (rangs MPI, defaut 8), RUNS_ROOT (defaut /opt/runs), WRF_HOME (defaut /comsoftware/wrf/WRF-4.6.1)
set -euo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNS_ROOT="${RUNS_ROOT:-/opt/runs}"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
NP="${NP:-8}"
WORK="$RUNS_ROOT/cases/rrtmg_gprof/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
cd "$WORK"
ln -sf "$WRF_HOME/main/ideal.exe" ideal.exe
ln -sf "$WRF_HOME/main/wrf.exe.gprof" wrf.exe
[ -x ./ideal.exe ] || { echo "ECHEC: $WRF_HOME/main/ideal.exe absent"; exit 1; }
[ -x ./wrf.exe ]   || { echo "ECHEC: $WRF_HOME/main/wrf.exe.gprof absent -> image sans variante gprof : 'docker/build.sh gprof' puis relancer le conteneur avec wrf-pinn:gprof"; exit 1; }
cp "$WRF_HOME/test/em_quarter_ss/input_sounding" .
cp "$CASE_DIR/namelist.input" .
# donnees lues par wrf.exe dans le cwd (RRTMG: RRTMG_LW_DATA/SW_DATA, ozone*, aerosol*, *.TBL)
for f in "$WRF_HOME"/run/*; do
  b="$(basename "$f")"
  case "$b" in namelist.input|*.exe|README*) continue ;; esac
  ln -sf "$f" "$b"
done
./ideal.exe > ideal.log 2>&1
# conteneur en root : OpenMPI exige --allow-run-as-root
# GMON_OUT_PREFIX -> un fichier gmon.out-<pid> PAR RANG MPI (sinon ils s'ecrasent)
export GMON_OUT_PREFIX=gmon.out
mpirun --allow-run-as-root -x GMON_OUT_PREFIX -np "$NP" ./wrf.exe > wrf.log 2>&1
ls gmon.out* > /dev/null 2>&1 || { echo "ECHEC: aucun gmon.out* produit -> wrf.exe non compile avec -pg (rebuild: docker/build.sh gprof)"; exit 1; }
# gprof somme directement tous les fichiers indiques
gprof ./wrf.exe gmon.out* > gprof.txt
mkdir -p out
mv -f rsl.* wrfout* gmon.out* gprof.txt out/ 2>/dev/null || true
echo "OK: run gprof termine dans $WORK"
echo "== top du flat profile (out/gprof.txt) =="
sed -n '/[Ff]lat profile/,/^$/p' out/gprof.txt | head -20
echo "== lignes taumol/rrtmg dans le profil =="
grep -iE "taumol|rrtmg" out/gprof.txt | head -20 || true
