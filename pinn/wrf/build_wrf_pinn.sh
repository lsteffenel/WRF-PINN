#!/usr/bin/env bash
# Build WRF avec le PINN (libtorch) : compile pinn_torch.cpp en libpinn_torch.so,
# patche les sources RRTMG, puis configure + compile em_quarter_ss avec libtorch
# dans le link. Le binaire wrf.exe utilisera le PINN si PINN_MODEL=<modele.script.pt>
# est dans l'env au run, sinon le Fortran de reference (fallback).
# Usage (dans le conteneur, python de l'env pinn actif) :
#   WRF_HOME=/comsoftware/wrf/WRF-4.6.1 bash /opt/pinn/wrf/build_wrf_pinn.sh [em_quarter_ss]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRF_HOME="${WRF_HOME:-/comsoftware/wrf/WRF-4.6.1}"
CASE="${1:-em_quarter_ss}"
CONDA_PREFIX="${CONDA_PREFIX:-/opt/conda/envs/pinn}"

# 1) libpinn_torch.so (libtorch de l'env conda pinn)
# libtorch 2.x exige GCC >= 9 : le g++ du conteneur (CentOS 7) est 4.8 -> on prend
# le toolchain conda-forge (x86_64-conda-linux-gnu-g++), sinon on l'installe.
CXX=""
for c in "$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++" "$CONDA_PREFIX/bin/g++" \
         g++-14 g++-13 g++-12 g++-11 g++-10 g++; do
  if command -v "$c" >/dev/null 2>&1; then
    v="$("$c" -dumpversion 2>/dev/null | cut -d. -f1)"
    if [ "${v:-0}" -ge 9 ]; then CXX="$c"; break; fi
  fi
done
if [ -z "$CXX" ]; then
  echo "Aucun g++ >= 9 trouve -> install conda-forge gxx_linux-64..."
  # conda n'est pas forcement dans le PATH root du conteneur : le chercher
  CONDA_BIN=""
  for c in "${CONDA_EXE:-}" "$CONDA_PREFIX/bin/conda" /opt/conda/bin/conda /opt/conda/condabin/conda; do
    if [ -n "$c" ] && [ -x "$c" ]; then CONDA_BIN="$c"; break; fi
  done
  [ -n "$CONDA_BIN" ] || { echo "ECHEC: binaire conda introuvable"; exit 1; }
  "$CONDA_BIN" install -y -p "$CONDA_PREFIX" -c conda-forge "gxx_linux-64>=11" || { echo "ECHEC install gxx"; exit 1; }
  CXX="$CONDA_PREFIX/bin/x86_64-conda-linux-gnu-g++"
fi
echo "CXX=$CXX ($("$CXX" -dumpversion))"
"$CXX" -O2 -fPIC -shared -std=c++17 \
  -I"$CONDA_PREFIX/include" -I"$CONDA_PREFIX/include/torch/csrc/api/include" \
  -L"$CONDA_PREFIX/lib" -ltorch -ltorch_cpu -lc10 -lstdc++ \
  -Wl,-rpath,"$CONDA_PREFIX/lib" \
  -o "$WRF_HOME/phys/libpinn_torch.so" "$HERE/pinn_torch.cpp"
echo "OK: $WRF_HOME/phys/libpinn_torch.so"

# 2) patch des sources RRTMG
bash "$HERE/patch_wrf.sh"

# 3) configure + compile WRF avec libpinn_torch + libtorch dans le link
cd "$WRF_HOME"
# choix dmpar gcc (le conteneur NCAR) : repondre automatiquement au prompt de configure
printf '35\n1\n' | ./configure > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
# ajoute le link PINN dans configure.wrf (LDFLAGS)
sed -i "s|^LDFLAGS_LOCAL.*|LDFLAGS_LOCAL = -L$WRF_HOME/phys -lpinn_torch -L$CONDA_PREFIX/lib -ltorch -ltorch_cpu -lc10 -lstdc++ -Wl,-rpath,$CONDA_PREFIX/lib -Wl,-rpath,$WRF_HOME/phys|" configure.wrf
grep -n "lpinn_torch" configure.wrf || { echo "ECHEC: LDFLAGS_LOCAL non patche"; exit 1; }
# ATTENTION: ./compile retourne 0 meme si le link final echoue
# ("make[1]: [Makefile:29: em_ideal] Error 1 (ignored)") -> on verifie les
# binaires explicitement, sinon on croit que le build a reussi.
./compile "$CASE" > "compile_$CASE.log" 2>&1 || true
for b in main/ideal.exe main/wrf.exe; do
  if [ ! -x "$WRF_HOME/$b" ]; then
    echo "ECHEC: $b absent apres compile (WRF ignore l'erreur de link final)"
    echo "--- erreurs Fortran dans compile_$CASE.log :"
    grep -n "Error:\|Fatal Error" "compile_$CASE.log" | head -20 || true
    echo "--- undefined reference :"
    grep -n "undefined reference" "compile_$CASE.log" | head -10 || true
    echo "--- tail du log :"
    tail -25 "compile_$CASE.log"
    exit 1
  fi
done
echo "OK: WRF compile avec PINN -> $WRF_HOME/main/ideal.exe + main/wrf.exe"
ls -la main/ideal.exe main/wrf.exe
