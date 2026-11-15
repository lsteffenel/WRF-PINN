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
RUN export NETCDF=/comsoftware/libs/netcdf/ \
    && export JASPERINC=/usr/include/jasper/ \
    && export JASPERLIB=/usr/lib64/ \
    && cd WRF-${WRF_VERSION} \
    && ./configure <<< $'34\r1\r' \
    && sed -i -e '/^DM_CC/ s/$/ -DMPI2_SUPPORT/' configure.wrf \
    && sed -i '/BUILD_RRTMG_FAST/d' configure.wrf \
    && /bin/csh ./compile em_real > compile.log 2>&1 \
    || { tail -n 60 compile.log; exit 1; }

RUN cd WRF-${WRF_VERSION} \
    && test -f main/wrf.exe && echo "OK: WRF compile -> main/wrf.exe" \
    || { echo 'ECHEC: main/wrf.exe absent'; \
         grep -nE "undefined reference|collect2|cannot find|Error" compile.log | grep -v ignored | tail -n 30; exit 1; }

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
# Build GPU pour l'entrainement du PINN (RTX 3070, driver NVIDIA 550 / CUDA 12.4) :
# sur conda-forge, la variante CUDA de pytorch se selectionne via le paquet virtuel
# __cuda (le meta-paquet pytorch-cuda a ete SUPPRIME de conda-forge ; "pytorch-gpu"
# n'existe que sur le canal "pytorch" d'Anaconda). Au build il n'y a pas de GPU :
# CONDA_OVERRIDE_CUDA=12.4 force __cuda=12.4 (driver 550 = CUDA 12.4 max) et
# CONDA_OVERRIDE_CUDA_ARCH=8.6 (RTX 3070, sm_86) ; "pytorch=*=cuda*" exige la
# variante CUDA (sinon le solveur prendrait la variante CPU sans driver detecte)
# et cuda-version=12.4 epingle les libs NVIDIA a 12.4.
# Lancer le conteneur avec --gpus all (nvidia-container-toolkit, cf. docs/INSTALL.md).
RUN curl -sSL -o /tmp/miniforge.sh \
       https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
    && bash /tmp/miniforge.sh -b -p /opt/conda && rm /tmp/miniforge.sh \
    && CONDA_OVERRIDE_CUDA=12.4 CONDA_OVERRIDE_CUDA_ARCH=8.6 \
       /opt/conda/bin/conda install -y -c conda-forge \
       python=3.11 numpy xarray netcdf4 h5py matplotlib pandas scipy "pytorch=*=cuda*" cuda-version=12.4 \
    && /opt/conda/bin/conda clean -ya > /dev/null \
    && /opt/conda/bin/python -c "import torch, xarray, netCDF4, h5py; assert torch.version.cuda == '12.4', 'variante CPU installee au lieu de CUDA !'; print('OK: PyTorch', torch.__version__, '| build CUDA', torch.version.cuda, '| cuda dispo (build sans GPU):', torch.cuda.is_available())"

ENV PATH /opt/conda/bin:$PATH
ENV LD_LIBRARY_PATH /usr/lib64/openmpi/lib:/comsoftware/libs/netcdf/lib
ENV PATH /usr/lib64/openmpi/bin:$PATH
ENV OMP_NUM_THREADS=1
WORKDIR /comsoftware/wrf/WRF-${WRF_VERSION}
# openmpi dans le conteneur : mpirun single-machine (48 cœurs OK)
ENTRYPOINT ["/bin/bash"]
