# WRF (RRTMG) — recette basee sur le conteneur officiel NCAR/DTC
# (https://github.com/NCAR/container-dtc-nwp, components/wps_wrf)
# Base : dtcenter/common-community-container:1.1 — pile preinstallee et eprouvee
# avec WRF : gfortran + OpenMPI + netcdf + jasper (pas de LTO, pas de paquets noble)
# Build:  docker build -t wrf-pinn:latest -f docker/Dockerfile .
FROM dtcenter/common-community-container:1.1

# WRF v4.6.1 (corrige le bug module_dm de v4.6.0, PR wrf-model/WRF#2069)
ARG WRF_VERSION=4.6.1
ARG WPS_VERSION=4.6.0
# Sous-module git phys/noahmp epingle par WRF v4.6.1 (.gitmodules -> NCAR/noahmp).
# Les tarballs GitHub auto-generes ne contiennent PAS les sous-modules : sans
# phys/noahmp/{drivers,src,parameters}, le Makefile de WRF echoue (exit 31,
# "NoahMP submodule files not populating WRF directories") et wrf.exe n'est pas produit.
ARG NOAHMP_COMMIT=848f54ad3d28c4303151fe5ad83724e232694422
# Variante profilage gprof : --build-arg BUILD_GPROF=1 (voir docker/build.sh gprof)
# ajoute -pg a FCOPTIM/LDFLAGS et produit main/wrf.exe.gprof + main/ideal.exe.gprof
# EN PLUS des binaires normaux (sauvegardes/restores car chaque ./compile em_* ZAPe
# main/wrf.exe et main/ideal.exe avant de rebuilder).
ARG BUILD_GPROF=0

USER root
WORKDIR /comsoftware/wrf

RUN curl -SL https://github.com/wrf-model/WRF/archive/v${WRF_VERSION}.tar.gz | tar zxC /comsoftware/wrf \
    && curl -SL https://github.com/wrf-model/WPS/archive/v${WPS_VERSION}.tar.gz | tar zxC /comsoftware/wrf \
    && mkdir -p /comsoftware/wrf/WRF-${WRF_VERSION}/phys/noahmp \
    && curl -SL https://github.com/NCAR/noahmp/archive/${NOAHMP_COMMIT}.tar.gz \
       | tar zxC /comsoftware/wrf/WRF-${WRF_VERSION}/phys/noahmp --strip-components=1 \
    && test -f /comsoftware/wrf/WRF-${WRF_VERSION}/phys/noahmp/drivers/wrf/module_sf_noahmpdrv.F \
    && test -f /comsoftware/wrf/WRF-${WRF_VERSION}/phys/noahmp/parameters/MPTABLE.TBL

# ---- WRF : etapes identiques a la recette NCAR (options 34 puis 1 au configure) ----
# em_real -> main/wrf.exe + main/real.exe (cas reels), puis em_quarter_ss (cas
# idealise du smoke test runs/cases/em_quarter_ss) -> main/ideal.exe + liens dans
# test/em_quarter_ss. ATTENTION : il n'existe PAS de cible "em_ideal" dans le
# Makefile, et chaque "./compile em_*" supprime d'abord main/wrf.exe (ZAP dans le
# script compile) : em_quarter_ss depend de la cible "wrf" qui reconstruit
# main/wrf.exe avant de construire main/ideal.exe, donc les deux coexistent.
RUN export NETCDF=/comsoftware/libs/netcdf/ \
    && export JASPERINC=/usr/include/jasper/ \
    && export JASPERLIB=/usr/lib64/ \
    && cd WRF-${WRF_VERSION} \
    && ./configure <<< $'34\r1\r' \
    && sed -i -e '/^DM_CC/ s/$/ -DMPI2_SUPPORT/' configure.wrf \
    && sed -i '/BUILD_RRTMG_FAST/d' configure.wrf \
    && /bin/csh ./compile em_real > compile.log 2>&1 \
    && /bin/csh ./compile em_quarter_ss > compile_quarter_ss.log 2>&1 \
    || { tail -n 60 compile.log; tail -n 60 compile_quarter_ss.log 2>/dev/null; exit 1; }

RUN cd WRF-${WRF_VERSION} \
    && test -f main/wrf.exe && test -f main/real.exe && test -f main/ideal.exe \
    && echo "OK: WRF compile -> main/wrf.exe + main/real.exe + main/ideal.exe" \
    || { echo 'ECHEC: main/wrf.exe, main/real.exe ou main/ideal.exe absent'; \
         grep -nE "undefined reference|collect2|cannot find|Error" compile.log compile_quarter_ss.log 2>/dev/null | grep -v ignored | tail -n 30; exit 1; }

# ---- Variante gprof (optionnelle, BUILD_GPROF=1) : binaires *-pg en *.gprof ----
# PIege : make ne depend pas de configure.wrf pour les .o -> un simple recompile apres
# le sed reutilise les objets SANS -pg (pas de gmon.out au run). On touche donc toutes
# les sources pour forcer la recompilation complete, et on verifie mcount dans le binaire.
RUN cd WRF-${WRF_VERSION} \
    && cp -f main/wrf.exe /tmp/wrf.exe.rel && cp -f main/ideal.exe /tmp/ideal.exe.rel \
    && if [ "${BUILD_GPROF}" = "1" ]; then \
         sed -i -e 's/^FCOPTIM[[:space:]]*=/& -pg/' -e 's/^LDFLAGS[[:space:]]*=/& -pg/' configure.wrf \
         && find . \( -name '*.F' -o -name '*.f' -o -name '*.f90' -o -name '*.c' \) -exec touch {} + \
         && export NETCDF=/comsoftware/libs/netcdf/ JASPERINC=/usr/include/jasper/ JASPERLIB=/usr/lib64/ \
         && /bin/csh ./compile em_quarter_ss > compile_gprof.log 2>&1 \
         && nm main/wrf.exe | grep -q mcount \
         && mv -f main/wrf.exe main/wrf.exe.gprof && mv -f main/ideal.exe main/ideal.exe.gprof \
         && cp -f /tmp/wrf.exe.rel main/wrf.exe && cp -f /tmp/ideal.exe.rel main/ideal.exe \
         && echo "OK: build gprof -> main/wrf.exe.gprof (mcount present, binaires release restaures)"; \
       fi

# ---- WPS : configure option 1 (gfortran serial) ----
RUN ln -sf WRF-${WRF_VERSION} WRF \
    && cd WPS-${WPS_VERSION} \
    && export NETCDF=/comsoftware/libs/netcdf/ \
    && export JASPERINC=/usr/include/jasper/ \
    && export JASPERLIB=/usr/lib64/ \
    && export WRF_DIR=/comsoftware/wrf/WRF-${WRF_VERSION} \
    && ./configure <<< $'1\r' \
    && sed -i -e 's/-L$(NETCDF)\/lib/-L$(NETCDF)\/lib -lnetcdff /' configure.wps \
    && /bin/csh ./compile > compile.log 2>&1 \
    || { tail -n 60 compile.log; exit 1; }

RUN cd WPS-${WPS_VERSION} \
    && ls geogrid.exe metgrid.exe ungrib.exe \
    || { echo 'ECHEC: executables WPS absents'; tail -n 30 compile.log; exit 1; }

# ---- Environnement Python pour le PINN (Miniforge, compatible glibc 2.17/CentOS 7) ----
# Les paquets conda-forge sont construits sur une baseline CentOS 7 : Python recent,
# stack scientifique (generation de donnees) et PyTorch (developpement du modele)
# s'installent sans toucher au systeme de base.
# Environnement "pinn" cree dans /opt/conda/envs/pinn via le conda de la base
# Miniforge (un env conda ne contient pas l'executable conda lui-meme : la base
# reste donc en place pour l'outil, seul le cache pkgs est purge a la fin).
#  - matplotlib-base au lieu de matplotlib : le metapaquet matplotlib tire
#    qt6-main + pyside6 (~70 Mo) inutiles en headless ; matplotlib-base suffit
#    pour matplotlib.use('Agg').
# Build GPU pour l'entrainement du PINN (RTX 3070, driver NVIDIA 550 / CUDA 12.4) :
# sur conda-forge, la variante CUDA de pytorch se selectionne via le paquet virtuel
# __cuda. Au build il n'y a pas de GPU : CONDA_OVERRIDE_CUDA=12.4 force __cuda=12.4
# (driver 550 = CUDA 12.4 max) ; "pytorch=*=cuda*" exige la variante CUDA (sinon le
# solveur prendrait la variante CPU sans driver detecte) et cuda-version=12.4 epingle
# les libs NVIDIA a 12.4.
# NOTE : les builds conda-forge de pytorch sont compiles contre le toolkit CUDA 12.0
# (build string "cuda120"), donc torch.version.cuda == '12.0' meme avec des libs
# NVIDIA 12.4. C'est correct et compatible au runtime : un binaire CUDA 12.0 tourne
# avec un driver 550 (compatibilite descendante CUDA minor garantie). La variante
# CPU, elle, donnerait torch.version.cuda is None : c'est ce qu'on verifie.
# Lancer le conteneur avec --gpus all (nvidia-container-toolkit, cf. docs/INSTALL.md).
RUN curl -sSL -o /tmp/miniforge.sh \
       https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/miniforge.sh -b -p /opt/conda && rm /tmp/miniforge.sh \
    && CONDA_OVERRIDE_CUDA=12.4 CONDA_OVERRIDE_CUDA_ARCH=8.6 \
       /opt/conda/bin/conda create -y -c conda-forge -n pinn \
       python=3.11 numpy xarray netcdf4 h5py matplotlib-base \
       pandas scipy "pytorch=*=cuda*" cuda-version=12.4 \
    || { echo 'ECHEC: conda create (voir log ci-dessus)'; exit 1; } \
    && /opt/conda/bin/conda clean -ya > /dev/null \
    && { /opt/conda/bin/conda list -n pinn pytorch | grep -qE 'cuda[0-9]+' \
         || { echo 'ECHEC: variante CPU installee au lieu de CUDA !'; exit 1; }; } \
    && ln -sf /opt/conda/envs/pinn/bin/python /usr/local/bin/python \
    && ln -sf /opt/conda/envs/pinn/bin/pip /usr/local/bin/pip \
    && /usr/local/bin/python -c "import torch, xarray, netCDF4, h5py, matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot; assert torch.version.cuda is not None, 'variante CPU installee au lieu de CUDA !'; print('OK: PyTorch', torch.__version__, '| build CUDA', torch.version.cuda, '| cuda dispo (build sans GPU):', torch.cuda.is_available())"


ENV PATH /opt/conda/envs/pinn/bin:/opt/conda/bin:$PATH
ENV LD_LIBRARY_PATH /usr/lib64/openmpi/lib:/comsoftware/libs/netcdf/lib
ENV PATH /usr/lib64/openmpi/bin:$PATH
ENV OMP_NUM_THREADS=1
WORKDIR /comsoftware/wrf/WRF-${WRF_VERSION}
# openmpi dans le conteneur : mpirun single-machine (48 cœurs OK)
ENTRYPOINT ["/bin/bash"]
