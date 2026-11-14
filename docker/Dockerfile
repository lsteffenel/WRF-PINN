# WRF (RRTMG) sur Ubuntu 24.04 — image de build et d'exécution
# Build:  docker build -t wrf-pinn:latest -f docker/Dockerfile .
# (durée: 20-45 min selon machine; le build WRF est loggué dans /opt/WRF/compile.log)
FROM ubuntu:24.04

ARG WRF_VERSION=v4.6.0
ARG BUILD_WPS=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gfortran gfortran-12 \
        mpich libmpich-dev \
        libnetcdf-dev libnetcdff-dev \
        libpng-dev libjpeg-dev zlib1g-dev \
        libjasper-dev liblcms2-dev \
        pkg-config git curl ca-certificates file time \
    && rm -rf /var/lib/apt/lists/*

# GFortran 12 : plus sûr que le gfortran 13 par défaut d'Ubuntu 24.04 pour WRF
ENV FC=gfortran-12 F77=gfortran-12 F90=gfortran-12 CC=gcc CXX=g++ \
    NETCDF=/usr HDF=/usr JASPERLIB=/usr/lib JASPERINC=/usr/include

WORKDIR /opt

# ---- WRF ----
RUN git clone --depth 1 --branch ${WRF_VERSION} https://github.com/wrf-model/WRF.git
WORKDIR /opt/WRF
RUN echo 34 | ./configure \
    # option 34 = x86_64 Linux, gfortran, dmpar (MPI)
    && sed -i 's/^FCOPTS/FCOPTS   -fallow-argument-mismatch -fno-range-check/' configure.wrf \
    && (./compile em_real > compile.log 2>&1 || (tail -n 100 compile.log && false)) \
    && ls -la main/wrf.exe main/wrfinput_em_d01 2>/dev/null || true

# ---- WPS (optionnel : prétraitement de cas réels) ----
WORKDIR /opt
RUN if [ "${BUILD_WPS}" = "1" ]; then \
        git clone --depth 1 --branch ${WRF_VERSION} https://github.com/wrf-model/WPS.git && \
        cd WPS && echo 1 | ./configure && \
        (./compile > compile.log 2>&1 || (tail -n 100 compile.log && false)) && \
        ls -ls geogrid.exe metgrid.exe ungrib.exe ; \
    fi

WORKDIR /opt/WRF
ENV OMP_NUM_THREADS=1
# mpich dans le conteneur : mpirun single-machine (48 cœurs OK)
ENTRYPOINT ["/bin/bash"]
