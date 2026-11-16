"""Modele v0 (PyTorch GPU) : emulation de taumol_sw / taumol (RRTMG) depuis le dataset HDF5.

Architecture : MLP partage sur les niveaux verticaux. Par niveau i (nlay+1 niveaux),
11 features brutes = [log10(plev), tlev, log10(h2o_niv), log10(o3_niv), co2, ch4, n2o,
o2, tsfc, log10(col_h2o_above), log10(col_o3_above)] -> standardisees (buffers du
module) -> MLP -> 504 sorties par niveau :
  [0:112]    = log1p(taug_sw)   (positions 0..nlay-1 = couches SW)
  [112:224]  = log1p(taur_sw)
  [224:364]  = log1p(taug_lw)   (positions 0..nlay)
  [364:504]  = logit(fracs_lw)
Loss : MSE en log1p pour taug/taur, MSE pour fracs (sigmoid). Export TorchScript
(--export) pour l'integration WRF ulterieure (libtorch, appel depuis Fortran).

Usage (dans le conteneur, python de l'env conda pinn) :
    /opt/conda/envs/pinn/bin/python3 /opt/pinn/train_v0.py \
        --h5 /opt/data/taumol_dataset.h5 --out /opt/data/taumol_v0.pt --epochs 100 --export
"""
import argparse
import os
import time
from typing import Tuple

import numpy as np

NFEAT = 11
NGPTSW = 112
NGPTLW = 140
NOUT = 2 * NGPTSW + 2 * NGPTLW


def build_features(play, plev, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
    play = np.asarray(play, dtype=np.float64)
    plev = np.asarray(plev, dtype=np.float64)
    tlev = np.asarray(tlev, dtype=np.float64)
    h2o = np.asarray(h2o, dtype=np.float64)
    o3 = np.asarray(o3, dtype=np.float64)
    nlay = play.size
    L = nlay + 1

    def to_niv(c):
        c = np.asarray(c, dtype=np.float64)
        v = np.empty(L)
        v[0] = c[0]
        v[-1] = c[-1]
        if nlay > 1:
            v[1:-1] = 0.5 * (c[:-1] + c[1:])
        return v

    h2o_n = to_niv(h2o)
    o3_n = to_niv(o3)
    co2_n = to_niv(co2)
    ch4_n = to_niv(ch4)
    n2o_n = to_niv(n2o)
    o2_n = to_niv(o2)
    dp = plev[:-1] - plev[1:]

    def col_above(c):
        cs = np.cumsum((c * dp)[::-1])[::-1]
        out = np.zeros(L)
        out[:nlay] = cs
        return out

    colh2o = col_above(h2o)
    colo3 = col_above(o3)
    F = np.stack([
        np.log10(plev), tlev, np.log10(h2o_n + 1e-12), np.log10(o3_n + 1e-12),
        co2_n, ch4_n, n2o_n, o2_n, np.full(L, float(tsfc)),
        np.log10(colh2o + 1e-12), np.log10(colo3 + 1e-12),
    ], axis=1)
    return F.astype(np.float32)


def load_h5(h5path):
    import h5py
    with h5py.File(h5path, "r") as f:
        nlay = int(f.attrs["nlay"])
        gx, gy = f["x"], f["y"]
        n = gx["play"].shape[0]
        play, plev = gx["play"][:], gx["plev"][:]
        tlev, tsfc = gx["tlev"][:], gx["tsfc"][:]
        h2o, o3 = gx["h2o"][:], gx["o3"][:]
        co2, ch4, n2o, o2 = gx["co2"][:], gx["ch4"][:], gx["n2o"][:], gx["o2"][:]
        X = np.stack([build_features(play[i], plev[i], tlev[i], tsfc[i],
                                     h2o[i], o3[i], co2[i], ch4[i], n2o[i], o2[i])
                      for i in range(n)], axis=0)
        y_sw = np.concatenate([gy["sw_taug"][:], gy["sw_taur"][:]], axis=2).astype(np.float32)
        y_lw = np.concatenate([gy["lw_taug"][:], gy["lw_fracs"][:]], axis=2).astype(np.float32)
    return nlay, X, y_sw, y_lw


def make_model(hidden, nhidden):
    import torch

    class TaumolV0(torch.nn.Module):
        def __init__(self, hidden=hidden, nhidden=nhidden):
            super().__init__()
            self.ngptsw = NGPTSW
            self.ngptlw = NGPTLW
            self.nout = NOUT
            self.register_buffer("feat_mean", torch.zeros(1, 1, NFEAT))
            self.register_buffer("feat_std", torch.ones(1, 1, NFEAT))
            layers = [torch.nn.Linear(NFEAT, hidden), torch.nn.SiLU()]
            for _ in range(nhidden - 1):
                layers += [torch.nn.Linear(hidden, hidden), torch.nn.SiLU()]
            layers += [torch.nn.Linear(hidden, NOUT)]
            self.net = torch.nn.Sequential(*layers)

        def forward(self, X: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
            Z = (X - self.feat_mean) / self.feat_std
            B, L, F = Z.shape
            H = self.net(Z.reshape(B * L, F)).reshape(B, L, self.nout)
            taug_sw = torch.expm1(H[:, :-1, 0:self.ngptsw])
            taur_sw = torch.expm1(H[:, :-1, self.ngptsw:2 * self.ngptsw])
            taug_lw = torch.expm1(H[:, :, 2 * self.ngptsw:2 * self.ngptsw + self.ngptlw])
            fracs_lw = torch.sigmoid(H[:, :, 2 * self.ngptsw + self.ngptlw:])
            return taug_sw, taur_sw, taug_lw, fracs_lw

    return TaumolV0()


def loss_and_metrics(pred, y_sw, y_lw, w_lw):
    import torch
    taug_sw, taur_sw, taug_lw, fracs_lw = pred
    y_taug_sw = y_sw[..., :NGPTSW].clamp_min(-0.5)
    y_taur_sw = y_sw[..., NGPTSW:].clamp_min(-0.5)
    y_taug_lw = y_lw[..., :NGPTLW].clamp_min(-0.5)
    y_fracs = y_lw[..., NGPTLW:]
    l_taug_sw = torch.mean((torch.log1p(taug_sw.clamp_min(0)) - torch.log1p(y_taug_sw)) ** 2)
    l_taur_sw = torch.mean((torch.log1p(taur_sw.clamp_min(0)) - torch.log1p(y_taur_sw)) ** 2)
    l_taug_lw = torch.mean((torch.log1p(taug_lw.clamp_min(0)) - torch.log1p(y_taug_lw)) ** 2)
    l_fracs = torch.mean((fracs_lw - y_fracs) ** 2)
    loss = l_taug_sw + l_taur_sw + w_lw * (l_taug_lw + l_fracs)
    with torch.no_grad():
        def relerr(p, y):
            return (torch.abs(p - y) / y.clamp_min(1e-3)).median().item()
        met = {
            "taug_sw": relerr(taug_sw, y_taug_sw),
            "taur_sw": relerr(taur_sw, y_taur_sw),
            "taug_lw": relerr(taug_lw, y_taug_lw),
            "fracs_lw": torch.abs(fracs_lw - y_fracs).mean().item(),
        }
    parts = {k: v.item() for k, v in
             [("l_taug_sw", l_taug_sw), ("l_taur_sw", l_taur_sw),
              ("l_taug_lw", l_taug_lw), ("l_fracs", l_fracs)]}
    return loss, parts, met


def main():
    import torch
    from torch.utils.data import DataLoader, Dataset

    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--h5", default="/opt/data/taumol_dataset.h5")
    ap.add_argument("--out", default="/opt/data/taumol_v0.pt")
    ap.add_argument("--epochs", type=int, default=100)
    ap.add_argument("--batch", type=int, default=256)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--val-frac", type=float, default=0.1)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--hidden", type=int, default=256)
    ap.add_argument("--nhidden", type=int, default=3)
    ap.add_argument("--w-lw", type=float, default=1.0, help="poids des termes LW dans la loss")
    ap.add_argument("--patience", type=int, default=15, help="early stopping (epoques sans amelioration val)")
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    ap.add_argument("--export", action="store_true", help="exporte aussi un TorchScript <out sans .pt>.script.pt")
    args = ap.parse_args()

    device = torch.device(args.device)
    print(f"device={device}")
    nlay, X, y_sw, y_lw = load_h5(args.h5)
    n = X.shape[0]
    print(f"dataset: N={n} nlay={nlay} X={X.shape} y_sw={y_sw.shape} y_lw={y_lw.shape}")

    rng = np.random.RandomState(args.seed)
    idx = rng.permutation(n)
    n_val = max(1, int(n * args.val_frac))
    val_idx, tr_idx = idx[:n_val], idx[n_val:]

    class TaumolDataset(Dataset):
        def __init__(self, X, y_sw, y_lw, sel):
            self.X = torch.from_numpy(X[sel])
            self.y_sw = torch.from_numpy(y_sw[sel])
            self.y_lw = torch.from_numpy(y_lw[sel])

        def __len__(self):
            return self.X.shape[0]

        def __getitem__(self, i):
            return self.X[i], self.y_sw[i], self.y_lw[i]

    tr = TaumolDataset(X, y_sw, y_lw, tr_idx)
    va = TaumolDataset(X, y_sw, y_lw, val_idx)
    tr_loader = DataLoader(tr, batch_size=args.batch, shuffle=True, drop_last=False)
    va_loader = DataLoader(va, batch_size=args.batch, shuffle=False)

    model = make_model(args.hidden, args.nhidden).to(device)
    mean = X[tr_idx].mean(axis=(0, 1))
    std = X[tr_idx].std(axis=(0, 1)) + 1e-8
    model.feat_mean.copy_(torch.tensor(mean, dtype=torch.float32, device=device).reshape(1, 1, -1))
    model.feat_std.copy_(torch.tensor(std, dtype=torch.float32, device=device).reshape(1, 1, -1))
    print(f"params={sum(p.numel() for p in model.parameters())} "
          f"train={len(tr)} val={len(va)} batch={args.batch}")

    opt = torch.optim.Adam(model.parameters(), lr=args.lr)
    sched = torch.optim.lr_scheduler.ReduceLROnPlateau(opt, patience=5, factor=0.5)

    best = float("inf")
    best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
    bad = 0
    t0 = time.time()
    for ep in range(1, args.epochs + 1):
        model.train()
        tr_loss = 0.0
        nb = 0
        for xb, ysw, ylw in tr_loader:
            xb = xb.to(device)
            ysw = ysw.to(device)
            ylw = ylw.to(device)
            pred = model(xb)
            loss, _, _ = loss_and_metrics(pred, ysw, ylw, args.w_lw)
            opt.zero_grad()
            loss.backward()
            opt.step()
            tr_loss += loss.item()
            nb += 1
        tr_loss /= max(nb, 1)
        model.eval()
        va_loss = 0.0
        met_sum = {}
        nb = 0
        with torch.no_grad():
            for xb, ysw, ylw in va_loader:
                xb = xb.to(device)
                ysw = ysw.to(device)
                ylw = ylw.to(device)
                pred = model(xb)
                loss, _, met = loss_and_metrics(pred, ysw, ylw, args.w_lw)
                va_loss += loss.item()
                nb += 1
                for k, v in met.items():
                    met_sum[k] = met_sum.get(k, 0.0) + v
        va_loss /= max(nb, 1)
        met = {k: v / max(nb, 1) for k, v in met_sum.items()}
        sched.step(va_loss)
        lr_now = opt.param_groups[0]["lr"]
        print(f"ep {ep:3d}/{args.epochs} train={tr_loss:.5f} val={va_loss:.5f} lr={lr_now:.2e} "
              f"medrelerr taug_sw={met['taug_sw']:.4f} taur_sw={met['taur_sw']:.4f} taug_lw={met['taug_lw']:.4f} "
              f"|dfracs|={met['fracs_lw']:.4f} ({time.time() - t0:.0f}s)", flush=True)
        if va_loss < best:
            best = va_loss
            best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
            bad = 0
        else:
            bad += 1
            if bad >= args.patience:
                print(f"early stopping a ep {ep} (best val={best:.5f})")
                break

    model.load_state_dict(best_state)
    model.eval()
    met_sum = {}
    nb = 0
    with torch.no_grad():
        for xb, ysw, ylw in va_loader:
            pred = model(xb.to(device))
            _, _, met = loss_and_metrics(pred, ysw.to(device), ylw.to(device), args.w_lw)
            nb += 1
            for k, v in met.items():
                met_sum[k] = met_sum.get(k, 0.0) + v
    metrics = {k: v / max(nb, 1) for k, v in met_sum.items()}
    metrics["val_loss"] = best
    print(f"OK: best val_loss={best:.5f} metrics={ {k: round(v, 5) for k, v in metrics.items()} }")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    torch.save({
        "state_dict": model.state_dict(),
        "feat_mean": model.feat_mean.detach().cpu(),
        "feat_std": model.feat_std.detach().cpu(),
        "nlay": nlay,
        "hidden": args.hidden,
        "nhidden": args.nhidden,
        "metrics": metrics,
        "h5": args.h5,
    }, args.out)
    print(f"OK: checkpoint -> {args.out}")

    if args.export:
        scripted = torch.jit.script(model.cpu().eval())
        export_path = os.path.splitext(args.out)[0] + ".script.pt"
        scripted.save(export_path)
        print(f"OK: TorchScript -> {export_path}")


if __name__ == "__main__":
    main()
