# WRF (RRTMG) sur Ubuntu 24.04 — image de build et d'exécution
# Build:  docker build -t wrf-pinn:latest -f docker/Dockerfile .
# (durée: 20-45 min selon machine; logs: /opt/WRF/compile.log, /opt/WPS/compile.log)
FROM ubuntu:24.04

ARG WRF_VERSION=v4.6.0
ARG BUILD_WPS=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gfortran gfortran-12 m4 csh \
        mpich libmpich-dev \
        libnetcdf-dev libnetcdff-dev \
        libpng-dev libjpeg-dev zlib1g-dev \
        pkg-config git curl ca-certificates file time \
    && rm -rf /var/lib/apt/lists/*

# GFortran 12 : plus sûr que le gfortran 13 par défaut d'Ubuntu 24.04 pour WRF
ENV FC=gfortran-12 F77=gfortran-12 F90=gfortran-12 CC=gcc CXX=g++ \
    NETCDF=/usr HDF=/usr

WORKDIR /opt

# ---- WRF ----
RUN git clone --depth 1 --branch ${WRF_VERSION} https://github.com/wrf-model/WRF.git

WORKDIR /opt/WRF
# option 34 = x86_64 Linux, gfortran, dmpar (MPI)
RUN echo 34 | ./configure

RUN ./compile em_real > compile.log 2>&1 \
    || { tail -n 100 compile.log; exit 1; }

RUN test -f main/wrf.exe && echo "OK: WRF compile -> main/wrf.exe"

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
