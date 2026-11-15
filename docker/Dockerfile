# WRF (RRTMG) — recette basee sur le conteneur officiel NCAR/DTC
# (https://github.com/NCAR/container-dtc-nwp, components/wps_wrf)
# Base : dtcenter/common-community-container:1.1 — pile preinstallee et eprouvee
# avec WRF : gfortran + OpenMPI + netcdf + jasper (pas de LTO, pas de paquets noble)
# Build:  docker build -t wrf-pinn:latest -f docker/Dockerfile .
FROM dtcenter/common-community-container:1.1

# WRF v4.6.1 (corrige le bug module_dm de v4.6.0, PR wrf-model/WRF#2069)
ARG WRF_VERSION=4.6.1
ARG WPS_VERSION=4.6.0

USER root
WORKDIR /comsoftware/wrf

RUN curl -SL https://github.com/wrf-model/WRF/archive/v${WRF_VERSION}.tar.gz | tar zxC /comsoftware/wrf \
    && curl -SL https://github.com/wrf-model/WPS/archive/v${WPS_VERSION}.tar.gz | tar zxC /comsoftware/wrf

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

ENV LD_LIBRARY_PATH /usr/lib64/openmpi/lib:/comsoftware/libs/netcdf/lib
ENV PATH /usr/lib64/openmpi/bin:$PATH
ENV OMP_NUM_THREADS=1
WORKDIR /comsoftware/wrf/WRF-${WRF_VERSION}
# openmpi dans le conteneur : mpirun single-machine (48 cœurs OK)
ENTRYPOINT ["/bin/bash"]
