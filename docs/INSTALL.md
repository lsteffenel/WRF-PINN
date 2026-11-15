# Installation de WRF pour le profilage (serveur « 2kk »)

## Caractéristiques prises en compte

- Ubuntu 24.04 LTS, 2× Xeon Silver 4214R (2 sockets × 12 cœurs, 48 threads), 64 Go RAM
- GPUs : RTX 3070 (8 Go) + Quadro P2200 — inutiles pour WRF (CPU + MPI), utiles plus tard pour l'entraînement NN
- **`/` est plein à 94 % (13,5 Go libres)** → tout installer sur `/mnt/2ToDisk` (235 Go libres)
- Ubuntu 24.04 = gfortran 13 par défaut ; **utiliser gfortran-12** pour WRF (moins de surprises)
- Driver NVIDIA 550 / CUDA 12.4 : OK pour PyTorch plus tard

## Docker : oui, recommandé

**Avantages** (forts dans notre cas) :
- Reproductibilité exacte de l'environnement de build (WRF est très sensible aux versions GCC/NetCDF/MPI)
- Évite les conflits avec les paquets du système (pas de risque de casser le serveur)
- Image réutilisable pour l'intégration NN : plus tard on ajoutera PyTorch/libtorch + `nvidia-container-toolkit` (les GPUs sont déjà détectables par le driver 550)
- Performance quasi native (overhead < 2 %) ; MPI single-machine dans le conteneur sur 48 cœurs : sans problème

**Limites (mineures)** :
- `perf`/tracing noyau nécessite des droits étendus (`--cap-add SYS_ADMIN --security-opt seccomp=unconfined`) ; **gprof fonctionne sans privilège** → on profile avec `-pg` + gprof
- Les données volumineuses restent sur l'hôte via bind mount (`/mnt/3ToDisk`, ou `/mnt/2ToDisk` pour les geodata/sorties volumineuses)

### Installation Docker (hôte)

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker angelo   # puis relogin
# pour plus tard (GPU) :
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
```

### Build et exécution

```bash
git clone https://github.com/lsteffenel/WRF-PINN.git /mnt/2ToDisk/WRF-PINN
cd /mnt/2ToDisk/WRF-PINN
docker/build.sh                 # build WRF v4.6.0 + WPS (20-45 min)
docker/run.sh                   # shell dans le conteneur, /opt/runs monté sur l'hôte
```

Dans le conteneur, WRF est dans `/comsoftware/wrf/WRF-4.6.1` (`main/wrf.exe`, `main/real.exe`, `main/ideal.exe` compilés `em_real`) et WPS dans `/comsoftware/wrf/WPS-4.6.0`. L'environnement Python `pinn` (PyTorch CUDA) est actif via le `PATH` (`python` → `/opt/conda/envs/pinn/bin/python`).

### Premier run dans le conteneur (smoke test, sans WPS_GEOG)

```bash
./docker/build.sh                        # image wrf-pinn:latest (une fois)
./docker/run.sh /chemin/vers/WRF-PINN    # conteneur : <repo>/runs monté sur /opt/runs, <repo>/data sur /opt/data
# dans le conteneur :
bash /opt/runs/cases/em_quarter_ss/run.sh      # cas idéalisé 42x42x41, 60 min (smoke test)
NP=16 bash /opt/runs/cases/rrtmg_on_off/run.sh # profilage radiation RRTMG on/off (radt=10)
```

Les sorties (`rsl.*`, `wrfout*`, logs) tombent dans `runs/cases/<cas>/run-<timestamp>/` côté hôte (ignoré par git). Le cas idéalisé ne nécessite **aucune** donnée WPS_GEOG. Pour les cas réels avec WPS 4.6 : package géog **V4** (low-res pour les tests, high-res ~29 Go en production) dans `<repo>/data/WPS_GEOG`, et `geog_data_path = '/opt/data/WPS_GEOG'` dans `namelist.wps` — un WPS_GEOG V3 n'est pas compatible avec WPS 4.6 par défaut (voir `runs/README.md`).

## Alternative : installation native (si vous refusez Docker)

Résumé ; les mêmes étapes sont dans le Dockerfile, qui sert de référence.

```bash
sudo apt-get update
sudo apt-get install -y build-essential gfortran-12 mpich libmpich-dev \
  libnetcdf-dev libnetcdff-dev libpng-dev libjpeg-dev zlib1g-dev \
  libjasper-dev pkg-config git time

export FC=gfortran-12 F77=gfortran-12 CC=gcc
export NETCDF=/usr HDF=/usr

cd /mnt/2ToDisk
git clone --depth 1 --branch v4.6.0 https://github.com/wrf-model/WRF.git
cd WRF && echo 34 | ./configure     # x86_64, gfortran, dmpar
./compile em_real 2>&1 | tee compile.log
# vérifier: ls main/wrf.exe
```

WPS (pour les cas réels, données GFS/ERA5) :

```bash
cd /mnt/2ToDisk
git clone --depth 1 --branch v4.6.0 https://github.com/wrf-model/WPS.git
cd WPS && echo 1 | ./configure && ./compile 2>&1 | tee compile.log
```

Geodata WPS (~30 Go, optionnel pour un premier profilage avec un cas de test fourni) :
`https://www2.mmm.ucar.edu/wrf/users/download/get-sources-wps-geodata.html` → à décompresser dans `/mnt/2ToDisk/WPS/geog`.

## Profilage (étape suivante du plan, cf. `docs/CONTEXTE.md`)

1. **Timings intégrés WRF** (zéro outillage) : dans `rsl.out.0000`, les lignes
   `Timing for main: time ... on domain 2: ... seconds` donnent le coût par pas de temps.
   Comparer un run `ra_sw_phys=0/ra_lw_phys=0` (désactivés) vs `RRTMG` (4,4/1,4,4,4,4,4,4,4,4)
   → estimation directe de la part radiation, sans recompilation.
2. **gprof** : recompiler avec `-pg` (l'ajouter dans `configure.wrf` : `FCOPTS`/`LDFLAGS`),
   lancer `mpirun -np 24 ./wrf.exe`, puis `gprof wrf.exe gmon.out-0 > prof.txt`.
   Attention : gprof avec MPI ne mesure que le rang 0 — suffisant pour `taumol_*`.
3. Si besoin plus fin : TAU ou Score-P (nécessitent leurs propres builds).

## Cas de test recommandé pour le profilage

- Idéal : un cas **convection/nuages** (la part radiation varie selon la nébulosité, cf. CONTEXTE.md).
- Domaine ~200×200×40, `radt = 10` (plus petit que le défaut 30 pour rendre la radiation
  plus visible), microphysique + RRTMG LW/SW activés, 24-48 h de simulation.
- Faire deux configurations (radiation on/off) pour isoler la part `rrtmg_*`.
