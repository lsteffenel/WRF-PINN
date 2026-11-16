"""Generation du dataset d'entrainement taumol (option A).

Boucle sur les colonnes (time, y, x) des fichiers wrfout des runs WRF, construit
le profil d'entree de taumol_sw / taumol (RRTMG) et ecrit un dataset HDF5
extensible par blocs :

- x/*    : play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2 (float32)
- y/sw_taug, y/sw_taur : (N, nlay, 112)
- y/lw_taug, y/lw_fracs : (N, nlay+1, 140)
- meta/* : src_file, src_time, src_iy, src_ix (tracabilite de chaque colonne)

Usage (dans le conteneur, apres build.sh, avec le python de l'env conda pinn) :
    /opt/conda/envs/pinn/bin/python3 /opt/pinn/harness/gen_dataset.py \
        --wrfout '/opt/runs/cases/*/run-*/out/wrfout*' \
        --out /opt/data/taumol_dataset.h5 --max-samples 20000
"""
import argparse
import glob
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rrtmg_harness import RRTMG_Taumol, NGPTSW, NGPTLW  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

RD_CP = 0.2854
M_AIR_OVER_M_H2O = 1.6078
CO2_VMR = 400.0e-6
CH4_VMR = 1.8e-6
N2O_VMR = 0.32e-6
O2_VMR = 0.209

X_LAYER = ("play", "tlay", "h2o", "o3", "co2", "ch4", "n2o", "o2")
X_LEVEL = ("plev", "tlev")
X_SCALAR = ("tsfc",)
Y_NAMES = ("sw_taug", "sw_taur", "lw_taug", "lw_fracs")


def o3_profile(play):
    return 1.0e-6 * np.exp(-((np.log10(play) - 1.5) ** 2) / 0.5) + 1.0e-8


def column_from_wrfout(P, PB, T, QV, T2, iy, ix):
    p_pa = np.asarray(P[:, iy, ix], dtype=np.float64) + np.asarray(PB[:, iy, ix], dtype=np.float64)
    plev = p_pa / 100.0
    nlay = plev.size - 1
    play = 0.5 * (plev[:-1] + plev[1:])
    tlev = (np.asarray(T[:, iy, ix], dtype=np.float64) + 300.0) * (p_pa / 1.0e5) ** RD_CP
    tlay = 0.5 * (tlev[:-1] + tlev[1:])
    qv = np.asarray(QV[:, iy, ix], dtype=np.float64)
    h2o = 0.5 * (qv[:-1] + qv[1:]) * M_AIR_OVER_M_H2O
    tsfc = float(np.asarray(T2[iy, ix], dtype=np.float64)) if T2 is not None else float(tlev[0])
    prof = {
        "play": play, "plev": plev, "tlay": tlay, "tlev": tlev, "tsfc": tsfc,
        "h2o": h2o, "o3": o3_profile(play),
        "co2": np.full(nlay, CO2_VMR), "ch4": np.full(nlay, CH4_VMR),
        "n2o": np.full(nlay, N2O_VMR), "o2": np.full(nlay, O2_VMR),
    }
    return prof, nlay


def list_columns(patterns, stride_time, stride_xy):
    import netCDF4
    files = sorted({p for pat in patterns for p in glob.glob(pat)})
    coords = []
    for fi, path in enumerate(files):
        with netCDF4.Dataset(path) as ds:
            nt = len(ds.dimensions["Time"])
            ny = len(ds.dimensions["south_north"])
            nx = len(ds.dimensions["west_east"])
        for t in range(0, nt, stride_time):
            for iy in range(0, ny, stride_xy):
                for ix in range(0, nx, stride_xy):
                    coords.append((fi, t, iy, ix))
    return files, coords


def open_h5(path, nlay, overwrite):
    import h5py
    if overwrite and os.path.exists(path):
        os.remove(path)
    if os.path.exists(path):
        f = h5py.File(path, "a")
        if int(f.attrs["nlay"]) != nlay:
            f.close()
            sys.exit(f"nlay={nlay} incompatible avec le dataset existant {path} (nlay={int(f.attrs['nlay'])}), utiliser --overwrite")
        return f, f["x/play"].shape[0]
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    f = h5py.File(path, "w")
    f.attrs["nlay"] = nlay
    f.attrs["ngptsw"] = NGPTSW
    f.attrs["ngptlw"] = NGPTLW
    gx, gy, gm = f.create_group("x"), f.create_group("y"), f.create_group("meta")
    for name in X_LAYER:
        gx.create_dataset(name, (0, nlay), maxshape=(None, nlay), dtype="f4", chunks=True, compression="gzip")
    for name in X_LEVEL:
        gx.create_dataset(name, (0, nlay + 1), maxshape=(None, nlay + 1), dtype="f4", chunks=True, compression="gzip")
    for name in X_SCALAR:
        gx.create_dataset(name, (0,), maxshape=(None,), dtype="f4", chunks=True, compression="gzip")
    gy.create_dataset("sw_taug", (0, nlay, NGPTSW), maxshape=(None, nlay, NGPTSW), dtype="f4", chunks=True, compression="gzip")
    gy.create_dataset("sw_taur", (0, nlay, NGPTSW), maxshape=(None, nlay, NGPTSW), dtype="f4", chunks=True, compression="gzip")
    gy.create_dataset("lw_taug", (0, nlay + 1, NGPTLW), maxshape=(None, nlay + 1, NGPTLW), dtype="f4", chunks=True, compression="gzip")
    gy.create_dataset("lw_fracs", (0, nlay + 1, NGPTLW), maxshape=(None, nlay + 1, NGPTLW), dtype="f4", chunks=True, compression="gzip")
    vlen = h5py.special_dtype(vlen=str)
    gm.create_dataset("src_file", (0,), maxshape=(None,), dtype=vlen, chunks=True)
    for name in ("src_time", "src_iy", "src_ix"):
        gm.create_dataset(name, (0,), maxshape=(None,), dtype="i4", chunks=True)
    return f, 0


def flush(f, n0, bx, by, bmeta):
    k = len(bmeta["src_file"])
    if k == 0:
        return n0
    n1 = n0 + k
    for name in X_LAYER + X_LEVEL + X_SCALAR:
        d = f["x/" + name]
        d.resize(n1, axis=0)
        d[n0:n1] = np.asarray(bx[name], dtype=np.float32)
    for name in Y_NAMES:
        d = f["y/" + name]
        d.resize(n1, axis=0)
        d[n0:n1] = np.asarray(by[name], dtype=np.float32)
    gm = f["meta"]
    d = gm["src_file"]
    d.resize(n1, axis=0)
    d[n0:n1] = np.asarray(bmeta["src_file"], dtype=object)
    for name in ("src_time", "src_iy", "src_ix"):
        d = gm[name]
        d.resize(n1, axis=0)
        d[n0:n1] = np.asarray(bmeta[name], dtype=np.int32)
    f.flush()
    return n1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wrfout", nargs="+", default=["/opt/runs/cases/*/run-*/out/wrfout*"],
                    help="glob(s) des fichiers wrfout")
    ap.add_argument("--out", default="/opt/data/taumol_dataset.h5")
    ap.add_argument("--so", default=os.path.join(HERE, "build", "librrtmg_taumol.so"))
    ap.add_argument("--sw-data", default=os.path.join(HERE, "build", "RRTMG_SW_DATA"))
    ap.add_argument("--lw-data", default=os.path.join(HERE, "build", "RRTMG_LW_DATA"))
    ap.add_argument("--max-samples", type=int, default=20000)
    ap.add_argument("--stride-xy", type=int, default=1)
    ap.add_argument("--stride-time", type=int, default=1)
    ap.add_argument("--block", type=int, default=2048, help="nb de colonnes ecrites par bloc HDF5")
    ap.add_argument("--shuffle", action="store_true", help="melanger les colonnes avant generation")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--overwrite", action="store_true", help="ecraser le dataset de sortie s'il existe")
    args = ap.parse_args()

    files, coords = list_columns(args.wrfout, args.stride_time, args.stride_xy)
    if not files:
        sys.exit(f"Aucun fichier wrfout pour {args.wrfout}")
    print(f"{len(files)} fichier(s) wrfout, {len(coords)} colonnes candidates "
          f"(stride_time={args.stride_time}, stride_xy={args.stride_xy})")
    if args.shuffle:
        order = np.random.RandomState(args.seed).permutation(len(coords))
        coords = [coords[i] for i in order]
    coords = coords[: args.max_samples]
    print(f"-> {len(coords)} colonnes a generer (max-samples={args.max_samples})")

    r = RRTMG_Taumol(args.so, sw_data=args.sw_data, lw_data=args.lw_data)
    print("OK: init SW+LW (tables RRTMG chargees)")

    import netCDF4

    ds = None
    cur_fi = -1
    nlay = None
    f = None
    n0 = 0
    n = 0
    bad = 0
    skipped_nz = 0
    bx = {name: [] for name in X_LAYER + X_LEVEL + X_SCALAR}
    by = {name: [] for name in Y_NAMES}
    bmeta = {"src_file": [], "src_time": [], "src_iy": [], "src_ix": []}
    t0 = time.time()

    def read_var(name, t):
        v = ds.variables[name][t]
        return np.ma.filled(v, np.nan) if np.ma.isMaskedArray(v) else np.asarray(v)

    for fi, t, iy, ix in coords:
        if fi != cur_fi:
            if ds is not None:
                ds.close()
            ds = netCDF4.Dataset(files[fi])
            cur_fi = fi
        P, PB, T, QV = read_var("P", t), read_var("PB", t), read_var("T", t), read_var("QVAPOR", t)
        T2 = read_var("T2", t) if "T2" in ds.variables else None
        prof, nlay_col = column_from_wrfout(P, PB, T, QV, T2, iy, ix)
        if nlay is None:
            nlay = nlay_col
            f, n0 = open_h5(args.out, nlay, args.overwrite)
            f.attrs["created_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            f.attrs["wrfout"] = " ".join(args.wrfout)
            print(f"nlay={nlay} (nz={nlay + 1}), sortie: {args.out}")
        if nlay_col != nlay:
            skipped_nz += 1
            continue
        flat = np.concatenate([np.ravel(prof[k]) for k in ("play", "plev", "tlay", "tlev", "h2o", "o3")])
        if not np.all(np.isfinite(flat)) or np.any(prof["play"] <= 0) or np.any(prof["plev"] <= 0):
            bad += 1
            continue
        taug_sw, taur_sw = r.taumol_sw(prof["play"], prof["plev"], prof["tlay"], prof["tlev"],
                                       prof["tsfc"], prof["h2o"], prof["o3"], prof["co2"],
                                       prof["ch4"], prof["n2o"], prof["o2"])
        taug_lw, fracs_lw = r.taumol_lw(prof["play"], prof["plev"], prof["tlay"], prof["tlev"],
                                        prof["tsfc"], prof["h2o"], prof["o3"], prof["co2"],
                                        prof["ch4"], prof["n2o"], prof["o2"])
        if not (np.all(np.isfinite(taug_sw)) and taug_sw.sum() > 0
                and np.all(np.isfinite(taur_sw)) and np.all(np.isfinite(taug_lw))
                and np.all(np.isfinite(fracs_lw))):
            bad += 1
            continue
        for name in X_LAYER + X_LEVEL:
            bx[name].append(prof[name])
        bx["tsfc"].append(prof["tsfc"])
        by["sw_taug"].append(taug_sw)
        by["sw_taur"].append(taur_sw)
        by["lw_taug"].append(taug_lw)
        by["lw_fracs"].append(fracs_lw)
        bmeta["src_file"].append(os.path.basename(files[fi]))
        bmeta["src_time"].append(t)
        bmeta["src_iy"].append(iy)
        bmeta["src_ix"].append(ix)
        n += 1
        if n % args.block == 0:
            n0 = flush(f, n0, bx, by, bmeta)
            for d in (bx, by, bmeta):
                for k in d:
                    d[k].clear()
            print(f"[{n}/{len(coords)}] ecrits={n0} bad={bad} skipped_nz={skipped_nz} "
                  f"elapsed={time.time() - t0:.0f}s", flush=True)
        elif n % 500 == 0:
            print(f"[{n}/{len(coords)}] bad={bad} skipped_nz={skipped_nz} "
                  f"elapsed={time.time() - t0:.0f}s", flush=True)

    n0 = flush(f, n0, bx, by, bmeta)
    if ds is not None:
        ds.close()
    if f is not None:
        f.attrs["n_samples"] = n0
        f.close()
    if nlay is None:
        sys.exit("Aucune colonne valide (verifier --wrfout)")
    print(f"OK: {n0} echantillons -> {args.out} (nlay={nlay}, bad={bad}, "
          f"skipped_nz={skipped_nz}, {time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()
