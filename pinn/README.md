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
python3 /opt/pinn/harness/smoke_test.py    # profil standard -> taug/taur SW+LW + echantillon HDF5
```

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

## Étapes suivantes

1. `gen_dataset.py` : boucler sur des profils réalistes (depuis `wrfout*` des runs
   `runs/cases/*`, ou profils synthétiques variés) → dataset HDF5 (X = profils
   p/T/vmr + cossza ; Y = taug/taur SW et taug LW).
2. Modèle v0 (PyTorch GPU de l'env `pinn`) : MLP par g-point ou conv1d sur les couches.
3. Évaluation **physique** : comparer les heating rates / flux obtenus en
   remplaçant taumol dans le schéma (pas une MSE de τ).
4. Intégration WRF : `bind(C)` + libtorch batchée par tile, remplacement dans
   `module_ra_rrtmg_sw/lw`.
