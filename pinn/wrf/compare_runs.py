"""Compare deux wrfout (run Fortran ref vs run PINN) : heating rates radiation et flux.

Usage (python de l'env pinn) :
    /opt/conda/envs/pinn/bin/python3 /opt/pinn/wrf/compare_runs.py \
        run-ref/out/wrfout_d01_0001 run-pinn/out/wrfout_d01_0001
"""
import sys

import numpy as np

VARS = ["RTHRATEN", "RTHRATENLW", "RTHRATENSW", "RSHORT", "RLONG", "RSWOUT", "RLWTOA",
        "SWDOWN", "GLW", "OLR", "SWUPT", "SWDNT", "LWUPT", "LWDNT", "SWUPB", "LWDNB"]


def main():
    import netCDF4
    if len(sys.argv) < 3:
        sys.exit("usage: compare_runs.py <wrfout_ref> <wrfout_pinn>")
    ref, pinn = sys.argv[1], sys.argv[2]
    import os
    for p in (ref, pinn):
        if not p or not os.path.isfile(p):
            sys.exit(f"ECHEC: fichier introuvable: '{p}' (variables shell vides ?) "
                     f"-> definir REF=... et PIN=... avant, ex: "
                     f"REF=$(ls -dt /opt/runs/cases/rrtmg_on_off/run-* | sed -n 2p) "
                     f"PIN=$(ls -dt /opt/runs/cases/rrtmg_on_off/run-* | head -1)")
    a = netCDF4.Dataset(ref)
    b = netCDF4.Dataset(pinn)
    print(f"ref={ref}\npinn={pinn}")
    print(f"frames: ref={a.dimensions['Time'].size} pinn={b.dimensions['Time'].size} (comparaison sur la derniere frame)")
    for v in VARS:
        if v not in a.variables or v not in b.variables:
            print(f"{v:<12} absent")
            continue
        # derniere frame (la 1ere est a t=0, avant la 1ere radiation)
        x = np.ma.filled(a.variables[v][-1], np.nan).astype(np.float64)
        y = np.ma.filled(b.variables[v][-1], np.nan).astype(np.float64)
        d = y - x
        scale = np.nanmax(np.abs(x)) if np.nanmax(np.abs(x)) > 0 else 1.0
        print(f"{v:<12} max|ref|={np.nanmax(np.abs(x)):.4g}  mean|d|={np.nanmean(np.abs(d)):.4g} "
              f"max|d|={np.nanmax(np.abs(d)):.4g}  relmax={np.nanmax(np.abs(d)) / scale:.3%}")
    a.close()
    b.close()


if __name__ == "__main__":
    main()
