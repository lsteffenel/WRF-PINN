"""Compare deux wrfout (run Fortran ref vs run PINN) : heating rates radiation et flux.

Usage (python de l'env pinn) :
    /opt/conda/envs/pinn/bin/python3 /opt/pinn/wrf/compare_runs.py \
        run-ref/out/wrfout_d01_0001 run-pinn/out/wrfout_d01_0001
"""
import sys

import numpy as np

VARS = ["RTHRATEN", "RTHRATENLW", "RTHRATENSW", "RSHORT", "RLONG", "RSWOUT", "RLWTOA"]


def main():
    import netCDF4
    ref, pinn = sys.argv[1], sys.argv[2]
    a = netCDF4.Dataset(ref)
    b = netCDF4.Dataset(pinn)
    print(f"ref={ref}\npinn={pinn}")
    for v in VARS:
        if v not in a.variables or v not in b.variables:
            print(f"{v:<12} absent")
            continue
        x = np.ma.filled(a.variables[v][:], np.nan).astype(np.float64)
        y = np.ma.filled(b.variables[v][:], np.nan).astype(np.float64)
        d = y - x
        scale = np.nanmax(np.abs(x)) if np.nanmax(np.abs(x)) > 0 else 1.0
        print(f"{v:<12} max|ref|={np.nanmax(np.abs(x)):.4g}  mean|d|={np.nanmean(np.abs(d)):.4g} "
              f"max|d|={np.nanmax(np.abs(d)):.4g}  relmax={np.nanmax(np.abs(d)) / scale:.3%}")
    a.close()
    b.close()


if __name__ == "__main__":
    main()
