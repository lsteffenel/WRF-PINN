# pinn/ — émulation PINN de taumol_sw / taumol (RRTMG dans WRF)

Objectif (option A du plan, cf. `docs/CONTEXTE.md` §5) : remplacer les routines
`taumol_sw` (RRTMG_SW, 112 g-points après réduction 224→112) et `taumol`
(RRTMG_LW, 140 g-points) — qui calculent les **épaisseurs optiques** par couche
et par g-point — par un réseau de neurones. Le profilage gprof (`runs/cases/rrtmg_gprof`,
run de jour) montre `taumol_sw` ≈ 4,8 s ≈ 8× `taumol_lw` (0,6 s) sur ~104 s de CPU
sommé (16 rangs) : c'est la cible prioritaire.

## harness/ — appel standalone des routines Fortran

Dans le conteneur (`./docker/run.sh .`), avec le dépôt monté (ex. `/opt/pinn` si
`-v "$PWD":/opt/pinn`) :

```bash
bash /opt/pinn/harness/build.sh            # extrait les sources WRF + compile librrtmg_taumol.so
# smoke test avec le python de l'env conda pinn (h5py) ; python3 systeme = 3.6 sans h5py
/opt/conda/envs/pinn/bin/python3 /opt/pinn/harness/smoke_test.py
```

Le smoke test est OK : `taumol_sw` -> `taug`/`taur` (nlay×112) et `taumol_lw` ->
`taug`/`fracs` ((nlay+1)×140) positifs/finis, + un échantillon HDF5
(`out/taumol_sample.h5`).

- `extract_sources.sh` : extrait de `$WRF_HOME/phys/module_ra_rrtmg_{sw,lw}.F` les
  modules « core » (avant `MODULE module_ra_rrtmg_*`) + les loaders `sw_kgb16..29` /
  `lw_kgb01..16` (partie WRF, avec `wrf_dm_on_monitor` remplacé par un stub local).
- `pinn_taumol_api.f90` : wrapper `bind(C)` : `pinn_sw_init`, `pinn_sw_taumol`,
  `pinn_lw_init`, `pinn_lw_taumol`. Une colonne en entrée (pressions hPa, T K, vmr,
  cossza pour SW) → `taug`/`taur` (SW, nlay×112) et `taug`/`fracs` (LW, (nlay+1)×140).
  Le wrapper appelle `inatm_sw`/`inatm` + `setcoef_sw`/`setcoef` + `taumol_sw`/`taumol`,
  exactement comme `rrtmg_swrad`/`rrtmg_lwrad` (clear-sky, sans aérosol).
- `rrtmg_harness.py` : wrapper ctypes (numpy, column-major).
- `smoke_test.py` : profil standard, vérifie taug > 0, écrit `out/taumol_sample.h5`.

## gen_dataset.py — dataset HDF5 depuis les wrfout

Génère le dataset d'entraînement en bouclant sur les colonnes (time, y, x) des
`wrfout*` des runs (`/opt/runs` monté dans le conteneur) :

```bash
/opt/conda/envs/pinn/bin/python3 /opt/pinn/harness/gen_dataset.py \
    --wrfout '/opt/runs/cases/*/run-*/out/wrfout*' \
    --out /opt/data/taumol_dataset.h5 --max-samples 20000
```

- lit `P`, `PB`, `T`, `QVAPOR`, `T2` (netCDF4) ; par colonne : `plev=(P+PB)/100` hPa
  (nz niveaux, sol→haut), `play` = moyenne des niveaux (nlay = nz−1),
  `tlev=(T+300)·(p/1e5)^0.2854`, `tlay` = moyenne, `tsfc=T2`, `h2o≈qv·1.6078`,
  `o3` = profil analytique(log p), CO2/CH4/N2O/O2 constants (vmr) ;
- appelle `taumol_sw` + `taumol_lw` via le harness (clear-sky, comme WRF) ;
- écrit un HDF5 extensible par blocs (float32, gzip) : `x/*` = profils d'entrée,
  `y/sw_taug`/`y/sw_taur` (N, nlay, 112), `y/lw_taug`/`y/lw_fracs` (N, nlay+1, 140),
  `meta/*` = fichier/indices source de chaque colonne. Options : `--stride-xy`,
  `--stride-time`, `--max-samples`, `--block`, `--shuffle/--seed`, `--overwrite`
  (sinon reprend en append).

## train_v0.py — modèle v0 (PyTorch GPU, env `pinn`)

MLP partagé sur les niveaux verticaux. Par niveau (nlay+1), 14 features brutes
(`log10(plev)`, `tlev`, `tlay` au niveau, `log10(h2o/o3)` au niveau, `co2/ch4/n2o/o2`,
`tsfc`, `log10` des colonnes h2o/o3 intégrées au-dessus du niveau, `log10(dp)`,
`colmol=dp*100/g` en kg/m2 linéaire) → standardisées (buffers du module) → MLP
(512×3) → 504 sorties/niveau : `log1p(taug_sw)` 112 (couches 0..nlay−1),
`log10(taur_sw)` 112 (`taur=colmol(lay)*rayl(ig)` dans `taumol_sw`, dépend linéairement
de `colmol` et couvre 1e-7..0,26 → log10), `log1p(taug_lw)` 140, `logit(fracs_lw)` 140
(niveaux 0..nlay). Loss = MSE log1p (taug) + log10 (taur, poids `--w-taur`) + MSE (fracs).
Split 90/10, Adam + ReduceLROnPlateau + early stopping. Métriques : erreur relative
médiane globale **et** restreinte aux τ > 1e-2 (les g-points quasi transparents
faussent la médiane brute). `--export` produit un TorchScript (`*.script.pt`)
pour l'intégration WRF (libtorch).

```bash
/opt/conda/envs/pinn/bin/python3 /opt/pinn/train_v0.py \
    --h5 /opt/data/taumol_dataset.h5 --out /opt/data/taumol_v0.pt \
    --epochs 200 --export
```

## Étapes suivantes

1. ✅ harness standalone OK (smoke test : taug/taur SW + taug/fracs LW positifs).
2. ✅ `gen_dataset.py` : dataset HDF5 depuis les wrfout (voir ci-dessus).
3. `train_v0.py` : modèle v0 PyTorch GPU entraîné sur le HDF5 (voir ci-dessus), export TorchScript.
4. Évaluation **physique** : comparer les heating rates / flux obtenus en
   remplaçant taumol dans le schéma (pas une MSE de τ).
5. Intégration WRF : `bind(C)` + libtorch batché par tile, remplacement dans
   `module_ra_rrtmg_sw/lw`.
