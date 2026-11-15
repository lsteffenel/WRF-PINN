#!/usr/bin/env bash
# Analyse d'un run rrtmg_on_off : somme des "Timing for main" par variante
# (chaque ligne = elapsed depuis l'affichage precedent, donc on somme) et part
# de la radiation RRTMG = (total_rad_on - total_rad_off) / total_rad_off.
# Usage (dans le conteneur) : bash /opt/runs/cases/rrtmg_on_off/analyze.sh [run-dir]
#   sans argument : prend le run-* le plus recent
set -euo pipefail
RUN="${1:-$(ls -dt /opt/runs/cases/rrtmg_on_off/run-* | head -1)}"
tot() { grep "Timing for main" "$RUN/$1/out/rsl.out.0000" | awk '{s+=$(NF-2)} END {printf "%.4f", s}'; }
on=$(tot rad_on)
off=$(tot rad_off)
echo "run: $RUN"
echo "rad_on : total=${on} s"
echo "rad_off: total=${off} s"
awk -v on="$on" -v off="$off" 'BEGIN {
  d = on - off
  printf "radiation RRTMG: %.3f s  soit %.1f%% de rad_off (%.1f%% de rad_on)\n", d, 100*d/off, 100*d/on
}'
