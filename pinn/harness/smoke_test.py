"""Smoke test du harness taumol : un profil standard -> taumol_sw + taumol (LW),
verifie que les sorties sont positives/finies et ecrit un echantillon HDF5.

Usage (dans le conteneur, apres build.sh) :
    python3 /opt/pinn/harness/smoke_test.py [--so build/librrtmg_taumol.so] [--out out]
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rrtmg_harness import RRTMG_Taumol, NGPTSW, NGPTLW  # noqa: E402

WRF_RUN = os.environ.get("WRF_RUN", "/comsoftware/wrf/WRF-4.6.1/run")
# les donnees converties LE (.le) sont produites par build.sh a cote du .so
data_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build")


def standard_profile(nlay=40):
    """Profil simple type atmosphere standard : p log 1000->1 hPa, T 288->200 K,
    h2o/o3 décroissants, gaz traces constants (vmr)."""
    plev = np.logspace(np.log10(1000.0), np.log10(1.0), nlay + 1)
    play = np.sqrt(plev[:-1] * plev[1:])
    tlay = 288.0 - 2.2 * (np.log10(1000.0 / play))  # ~lapse 6.5 K/km en log-p
    tlay = np.clip(tlay, 180.0, 300.0)
    tlev = np.concatenate([[tlay[0] + 1.0], tlay])
    tsfc = 288.0
    h2o = 1.0e-2 * (play / 1000.0) ** 1.5          # vmr, decroit avec l'altitude
    o3 = 1.0e-6 * np.exp(-(np.log10(play) - 1.5) ** 2 / 0.5) + 1e-8
    co2 = np.full(nlay, 400.0e-6)
    ch4 = np.full(nlay, 1.8e-6)
    n2o = np.full(nlay, 0.32e-6)
    o2 = np.full(nlay, 0.209)
    return play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--so", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "build", "librrtmg_taumol.so"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
    args = ap.parse_args()

    r = RRTMG_Taumol(args.so,
                     sw_data=os.path.join(data_dir, "RRTMG_SW_DATA"),
                     lw_data=os.path.join(data_dir, "RRTMG_LW_DATA"))
    print("OK: init SW+LW (tables RRTMG chargees)")

    play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2 = standard_profile()
    n = len(play)

    taug_sw, taur_sw = r.taumol_sw(play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2)
    assert taug_sw.shape == (n, NGPTSW) and np.all(np.isfinite(taug_sw)) and taug_sw.sum() > 0
    assert taur_sw.shape == (n, NGPTSW) and np.all(np.isfinite(taur_sw)) and taur_sw.sum() > 0
    print(f"OK: taumol_sw  taug sum={taug_sw.sum():.4f} max={taug_sw.max():.4f} | taur sum={taur_sw.sum():.4f}")

    taug_lw, fracs = r.taumol_lw(play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2)
    assert taug_lw.shape == (n + 1, NGPTLW) and np.all(np.isfinite(taug_lw)) and taug_lw.sum() > 0
    print(f"OK: taumol_lw taug sum={taug_lw.sum():.4f} max={taug_lw.max():.4f} | fracs sum={fracs.sum():.4f}")

    os.makedirs(args.out, exist_ok=True)
    h5path = os.path.join(args.out, "taumol_sample.h5")
    import h5py
    with h5py.File(h5path, "w") as f:
        f.create_dataset("play", data=play)
        f.create_dataset("plev", data=plev)
        f.create_dataset("tlay", data=tlay)
        f.create_dataset("tlev", data=tlev)
        f.create_dataset("tsfc", data=tsfc)
        for name, v in [("h2o", h2o), ("o3", o3), ("co2", co2), ("ch4", ch4), ("n2o", n2o), ("o2", o2)]:
            f.create_dataset(name, data=v)
        f.attrs["cossza_meta"] = 0.5  # metadonnee (pas une entree de taumol_sw)
        g = f.create_group("sw")
        g.create_dataset("taug", data=taug_sw)
        g.create_dataset("taur", data=taur_sw)
        g = f.create_group("lw")
        g.create_dataset("taug", data=taug_lw)
        g.create_dataset("fracs", data=fracs)
    print(f"OK: echantillon HDF5 -> {h5path}")


if __name__ == "__main__":
    main()
