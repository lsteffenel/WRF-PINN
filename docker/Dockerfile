# WRF (RRTMG) sur Ubuntu 24.04 — image de build et d'exécution
# Build:  docker build -t wrf-pinn:latest -f docker/Dockerfile .
# (durée: 40-60 min; logs: /opt/WRF/compile.log, /opt/WPS/compile.log)
FROM ubuntu:24.04

ARG WRF_VERSION=v4.6.0
ARG NETCDFC_VERSION=4.9.2
ARG NETCDFF_VERSION=4.6.1
ARG BUILD_WPS=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gfortran gfortran-12 m4 csh \
        mpich libmpich-dev \
        libhdf5-dev libzip-dev libcurl4-openssl-dev libxml2-dev \
        libpng-dev libjpeg-dev zlib1g-dev \
        pkg-config git curl ca-certificates file time \
    && rm -rf /var/lib/apt/lists/*

# GFortran 12 : connu-bon pour WRF v4.6.0. Utilisable maintenant que la pile
# netcdf est construite par nous sans LTO (le problème initial venait de la
# libnetcdff des paquets noble, pas de gfortran-12). gfortran-13 compile mal
# certains fichiers WRF (symboles internes manquants au link final).
ENV FC=gfortran-12 F77=gfortran-12 F90=gfortran-12 CC=gcc CXX=g++

# ---- Pile NetCDF C + Fortran construite depuis les sources (sans LTO) ----
# Les paquets noble (libnetcdff) produisent des "undefined reference nf_*" au
# link WRF ; on construit une pile netcdf propre dans /opt/libs.
# NB: ne pas nommer cette variable LIBS (variable autoconf reservee)
RUN mkdir -p /opt/src && cd /opt/src \
    && curl -sSL -o netcdf-c.tar.gz \
       https://github.com/Unidata/netcdf-c/archive/refs/tags/v${NETCDFC_VERSION}.tar.gz \
    && tar xzf netcdf-c.tar.gz && cd netcdf-c-${NETCDFC_VERSION} \
    && CPPFLAGS="-I/usr/include/hdf5/serial" \
       LDFLAGS="-L/usr/lib/x86_64-linux-gnu/hdf5/serial" \
       ./configure --prefix=/opt/libs --disable-dap --enable-netcdf-4 \
    && make -j"$(nproc)" > /dev/null && make install

RUN cd /opt/src \
    && curl -sSL -o netcdf-fortran.tar.gz \
       https://github.com/Unidata/netcdf-fortran/archive/refs/tags/v${NETCDFF_VERSION}.tar.gz \
    && tar xzf netcdf-fortran.tar.gz && cd netcdf-fortran-${NETCDFF_VERSION} \
    && CPPFLAGS="-I/opt/libs/include -I/usr/include/hdf5/serial" \
       LDFLAGS="-L/opt/libs/lib -L/usr/lib/x86_64-linux-gnu/hdf5/serial" \
       ./configure --prefix=/opt/libs \
    && make -j"$(nproc)" > /dev/null && make install

RUN test -f /opt/libs/lib/libnetcdff.so && /opt/libs/bin/nc-config --has-hdf5

ENV NETCDF=/opt/libs PATH=/opt/libs/bin:$PATH

WORKDIR /opt

# ---- WRF ----
RUN git clone --depth 1 --branch ${WRF_VERSION} https://github.com/wrf-model/WRF.git

WORKDIR /opt/WRF
# option 34 = x86_64 Linux, gfortran, dmpar (MPI)
RUN echo 34 | ./configure

RUN ./compile em_real > compile.log 2>&1 \
    || { tail -n 100 compile.log; exit 1; }

RUN tail -n 40 compile.log || true

RUN test -f main/wrf.exe && echo "OK: WRF compile -> main/wrf.exe" \
    || { echo 'ECHEC: main/wrf.exe absent'; \
         grep -nE "undefined reference|collect2|cannot find" compile.log | tail -n 20; \
         echo '--- erreurs de compilation (non ignorees) ---'; \
         grep -n "Error" compile.log | grep -v ignored | tail -n 20; exit 1; }

# ---- WPS (optionnel : prétraitement de cas réels) ----
WORKDIR /opt
RUN if [ "${BUILD_WPS}" = "1" ]; then \
        git clone --depth 1 --branch ${WRF_VERSION} https://github.com/wrf-model/WPS.git; \
    fi

WORKDIR /opt/WPS
RUN if [ "${BUILD_WPS}" = "1" ]; then \
        export WRF_DIR=/opt/WRF && \
        echo 1 | ./configure && \
        ./compile > compile.log 2>&1 \
        || { tail -n 100 compile.log; exit 1; }; \
    fi

WORKDIR /opt/WRF
ENV OMP_NUM_THREADS=1
# mpich dans le conteneur : mpirun single-machine (48 cœurs OK)
ENTRYPOINT ["/bin/bash"]
