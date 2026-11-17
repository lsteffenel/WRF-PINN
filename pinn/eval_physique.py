"""Evaluation PHYSIQUE du PINN (option A, etape 4) : flux et heating rates.

Pour --n colonnes du dataset HDF5 :
  - taug/taur de reference = taumol_sw/taumol Fortran (librrtmg_taumol.so)
  - taug/taur PINN = TorchScript (--model) sur les features du profil
  - flux SW ref  = librrtmg_rad_ref.so  (spcvmc_sw avec le vrai taumol_sw)
    flux SW pinn = librrtmg_rad_pinn.so (spcvmc_sw avec le shell taumol_sw injecte)
  - flux LW ref/pinn = librrtmg_rad_ref.so pinn_lw_rad (rtrnmc recoit taug/fracs
    en entree : on passe ref ou PINN)
Compare : erreur relative du flux net au TOA (niveau n) et au sol (niveau 0),
RMSE du profil de flux net (W/m2), ecart des heating rates (mediane/max, K/jour).

Usage (dans le conteneur, python de l'env conda pinn, apres build.sh + build_rad.sh) :
    /opt/conda/envs/pinn/bin/python3 /opt/pinn/eval_physique.py \
        --h5 /opt/data/taumol_dataset.h5 --model /opt/data/taumol_v2.script.pt \
        --n 200 --cossza 0.5
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "harness"))
from rrtmg_harness import RRTMG_Taumol, RRTMG_Rad, NGPTSW, NGPTLW  # noqa: E402
from train_v0 import build_features, load_h5  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--h5", default="/opt/data/taumol_dataset.h5")
    ap.add_argument("--model", default="/opt/data/taumol_v2.script.pt")
    ap.add_argument("--n", type=int, default=200, help="nb de colonnes evaluees")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--so-taumol", default=os.path.join(HERE, "harness", "build", "librrtmg_taumol.so"))
    ap.add_argument("--so-rad-ref", default=os.path.join(HERE, "harness", "build", "rad_ref", "librrtmg_rad_ref.so"))
    ap.add_argument("--so-rad-pinn", default=os.path.join(HERE, "harness", "build", "rad_pinn", "librrtmg_rad_pinn.so"))
    ap.add_argument("--sw-data", default=os.path.join(HERE, "harness", "build", "RRTMG_SW_DATA"))
    ap.add_argument("--lw-data", default=os.path.join(HERE, "harness", "build", "RRTMG_LW_DATA"))
    ap.add_argument("--cossza", type=float, default=0.5)
    ap.add_argument("--alb", type=float, default=0.07)
    ap.add_argument("--emis", type=float, default=0.98)
    ap.add_argument("--out", default="", help="HDF5 optionnel des profils de flux ref/pinn")
    args = ap.parse_args()

    import torch

    nlay, X, y_sw, y_lw = load_h5(args.h5)
    n_all = X.shape[0]
    print(f"dataset: N={n_all} nlay={nlay}")

    taumol = RRTMG_Taumol(args.so_taumol, sw_data=args.sw_data, lw_data=args.lw_data)
    rad_ref = RRTMG_Rad(args.so_rad_ref,
                        sw_data=os.path.join(HERE, "harness", "build", "rad_ref", "RRTMG_SW_DATA"),
                        lw_data=os.path.join(HERE, "harness", "build", "rad_ref", "RRTMG_LW_DATA"))
    rad_pinn = RRTMG_Rad(args.so_rad_pinn,
                         sw_data=os.path.join(HERE, "harness", "build", "rad_pinn", "RRTMG_SW_DATA"),
                         lw_data=os.path.join(HERE, "harness", "build", "rad_pinn", "RRTMG_LW_DATA"))
    model = torch.jit.load(args.model).eval()
    print(f"model: {args.model}  rad ref/pinn charges")

    import h5py
    with h5py.File(args.h5, "r") as f:
        gx = f["x"]
        prof = {k: gx[k][:] for k in ("play", "plev", "tlay", "tlev", "tsfc",
                                      "h2o", "o3", "co2", "ch4", "n2o", "o2")}

    rng = np.random.RandomState(args.seed)
    idx = rng.choice(n_all, size=min(args.n, n_all), replace=False)

    sfluxzen = None
    res = {k: [] for k in (
        "sw_toa_relerr", "sw_sfc_relerr", "sw_fnet_rmse", "sw_hr_medabs", "sw_hr_maxabs",
        "lw_toa_relerr", "lw_sfc_relerr", "lw_fnet_rmse", "lw_hr_medabs", "lw_hr_maxabs",
    )}
    out = None
    if args.out:
        out = h5py.File(args.out, "w")
        out.attrs["nlay"] = nlay
        shapes = {"sw_fdn": nlay + 1, "sw_fup": nlay + 1, "sw_hr": nlay,
                  "lw_fdn": nlay + 1, "lw_fup": nlay + 1, "lw_hr": nlay + 1}
        for tag in ("ref", "pinn"):
            for k, m in shapes.items():
                out.create_dataset(f"{tag}/{k}", (0, m), maxshape=(None, m), dtype="f4")

    for j, i in enumerate(idx):
        P = {k: prof[k][i] for k in prof}
        args_prof = (P["play"], P["plev"], P["tlay"], P["tlev"], float(P["tsfc"]),
                     P["h2o"], P["o3"], P["co2"], P["ch4"], P["n2o"], P["o2"])

        taug_sw_r, taur_sw_r = taumol.taumol_sw(*args_prof)
        taug_lw_r, fracs_lw_r = taumol.taumol_lw(*args_prof)

        F = build_features(P["play"], P["plev"], P["tlev"], float(P["tsfc"]),
                           P["h2o"], P["o3"], P["co2"], P["ch4"], P["n2o"], P["o2"])
        with torch.no_grad():
            pred = model(torch.from_numpy(F[None]))
        taug_sw_p, taur_sw_p, taug_lw_p, fracs_lw_p = [t[0].numpy().astype(np.float64) for t in pred]

        if sfluxzen is None:
            sfluxzen = taumol.sw_sfluxzen(*args_prof)
            print(f"sfluxzen: min={sfluxzen.min():.4g} max={sfluxzen.max():.4g} sum={sfluxzen.sum():.4g}")

        fdn_r, fup_r, hr_sw_r = rad_ref.sw_rad(*args_prof, args.cossza, args.alb)
        rad_pinn.set_sw_ext(taug_sw_p, taur_sw_p, sfluxzen)
        fdn_p, fup_p, hr_sw_p = rad_pinn.sw_rad(*args_prof, args.cossza, args.alb)

        lfup_r, lfdn_r, hr_lw_r = rad_ref.lw_rad(*args_prof, args.emis, taug_lw_r, fracs_lw_r)
        lfup_p, lfdn_p, hr_lw_p = rad_ref.lw_rad(*args_prof, args.emis, taug_lw_p, fracs_lw_p)

        n = nlay
        fnet_sw_r, fnet_sw_p = fdn_r - fup_r, fdn_p - fup_p
        fnet_lw_r, fnet_lw_p = lfdn_r - lfup_r, lfdn_p - lfup_p
        res["sw_toa_relerr"].append(abs(fnet_sw_p[n] - fnet_sw_r[n]) / max(abs(fnet_sw_r[n]), 1e-6))
        res["sw_sfc_relerr"].append(abs(fnet_sw_p[0] - fnet_sw_r[0]) / max(abs(fnet_sw_r[0]), 1e-6))
        res["sw_fnet_rmse"].append(float(np.sqrt(np.mean((fnet_sw_p - fnet_sw_r) ** 2))))
        res["sw_hr_medabs"].append(float(np.median(np.abs(hr_sw_p - hr_sw_r))))
        res["sw_hr_maxabs"].append(float(np.max(np.abs(hr_sw_p - hr_sw_r))))
        res["lw_toa_relerr"].append(abs(fnet_lw_p[n] - fnet_lw_r[n]) / max(abs(fnet_lw_r[n]), 1e-6))
        res["lw_sfc_relerr"].append(abs(fnet_lw_p[0] - fnet_lw_r[0]) / max(abs(fnet_lw_r[0]), 1e-6))
        res["lw_fnet_rmse"].append(float(np.sqrt(np.mean((fnet_lw_p - fnet_lw_r) ** 2))))
        res["lw_hr_medabs"].append(float(np.median(np.abs(hr_lw_p - hr_lw_r))))
        res["lw_hr_maxabs"].append(float(np.max(np.abs(hr_lw_p - hr_lw_r))))

        if out is not None:
            for tag, (a, b, c) in (("ref", (fdn_r, fup_r, hr_sw_r)), ("pinn", (fdn_p, fup_p, hr_sw_p))):
                for k, v in (("sw_fdn", a), ("sw_fup", b), ("sw_hr", c)):
                    d = out[f"{tag}/{k}"]
                    d.resize(j + 1, axis=0)
                    d[j] = v
            for tag, (a, b, c) in (("ref", (lfdn_r, lfup_r, hr_lw_r)), ("pinn", (lfdn_p, lfup_p, hr_lw_p))):
                for k, v in (("lw_fdn", a), ("lw_fup", b), ("lw_hr", c)):
                    d = out[f"{tag}/{k}"]
                    d.resize(j + 1, axis=0)
                    d[j] = v

        if (j + 1) % 25 == 0:
            print(f"[{j+1}/{len(idx)}] colonnes OK", flush=True)

    if out is not None:
        out.close()
        print(f"OK: profils de flux -> {args.out}")

    print(f"\n=== evaluation physique sur {len(idx)} colonnes (cossza={args.cossza}, alb={args.alb}, emis={args.emis}) ===")
    print(f"{'metrique':<18} {'mediane':>12} {'moyenne':>12}")
    for k, v in res.items():
        v = np.asarray(v)
        print(f"{k:<18} {np.median(v):>12.5g} {v.mean():>12.5g}")


if __name__ == "__main__":
    main()
