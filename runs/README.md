# Organisation des expériences WRF

Les runs se font dans le conteneur (`docker/run.sh`), qui monte :

- `<repo>/runs` → `/opt/runs`
- `<repo>/data` → `/opt/data`

Conventions :

- `runs/cases/<nom-du-cas>/` : namelist(s) versionnés + `run.sh` du cas (dans git)
- chaque exécution crée `runs/cases/<cas>/run-<timestamp>/` (ignoré par git) avec
  `ideal.log`, `wrf*.log`, `rsl.*`, `wrfout*` → tout reste sur le disque hôte
- dans le conteneur : WRF dans `/comsoftware/wrf/WRF-4.6.1` (exécutables `main/ideal.exe`,
  `main/real.exe`, `main/wrf.exe`), WPS dans `/comsoftware/wrf/WPS-4.6.0`
- le conteneur tourne en root : les scripts utilisent `mpirun --allow-run-as-root`

Cas fournis :

- `cases/em_quarter_ss` : smoke test du conteneur — cas idéalisé livré avec WRF 4.6.1
  (42×42×41, dx=2000 m, 60 min, radiation OFF). **Aucune donnée WPS_GEOG requise.**
- `cases/rrtmg_on_off` : profilage de la part radiation RRTMG sur le même domaine
  (paire de runs `ra_lw/ra_sw_physics = 4` vs `0`, `radt=10`) ; les timings WRF sont
  dans `rsl.out.0000` (« Timing for main ... on domain 1 »), cf. `docs/CONTEXTE.md` §5.1.

Piège : avec la radiation active, `wrf.exe` lit `RRTMG_LW_DATA`, `RRTMG_SW_DATA`,
`ozone*`, `aerosol*`, `*.TBL` **dans le répertoire courant** (sinon un rang MPI meurt,
exit code 2). Le `run.sh` de `rrtmg_on_off` les symlink automatiquement depuis
`/comsoftware/wrf/WRF-4.6.1/run/`.

Analyse : `bash /opt/runs/cases/rrtmg_on_off/analyze.sh [run-dir]` somme les lignes
« Timing for main » de `rad_on`/`rad_off` (elapsed **par intervalle**, donc on somme)
et affiche la part radiation = (rad_on − rad_off) / rad_off.
- `cases/rrtmg_gprof` : profilage fin gprof (radiation RRTMG ON). Nécessite l'image
  `wrf-pinn:gprof` (`docker/build.sh gprof`, binaires `main/*.exe.gprof` avec `-pg`),
  puis `./docker/run.sh . gprof` (2e argument = tag d'image) et dans ce conteneur :
  `bash /opt/runs/cases/rrtmg_gprof/run.sh` → `out/gprof.txt`
  + extraction des lignes `taumol`/`rrtmg`. Mesure de référence rrtmg_on_off
  (em_quarter_ss, NP=16, radt=10) : radiation = 0.672 s ≈ 9.3 % du run.

Pour les cas réels (WPS 4.6) : déposer le package géog **V4** (low-res pour les tests,
high-res ~29 Go pour la production) dans `<repo>/data/WPS_GEOG` et mettre
`geog_data_path = '/opt/data/WPS_GEOG'` dans `namelist.wps`. Un WPS_GEOG V3 n'est PAS
compatible avec WPS 4.6 par défaut (jeux obligatoires V3 ≠ V4, cf. page UCAR geog_data).
