"""Wrapper ctypes de librrtmg_taumol.so : appel de taumol_sw / taumol (RRTMG WRF 4.6.1).

Usage (dans le conteneur, apres build.sh) :
    from rrtmg_harness import RRTMG_Taumol
    r = RRTMG_Taumol("build/librrtmg_taumol.so",
                    sw_data="/comsoftware/wrf/WRF-4.6.1/run/RRTMG_SW_DATA",
                    lw_data="/comsoftware/wrf/WRF-4.6.1/run/RRTMG_LW_DATA")
    taug, taur = r.taumol_sw(play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2)
    taug_lw, fracs = r.taumol_lw(play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2)

Conventions : pressions en hPa (play couches nlay, plev niveaux 0..nlay), temperatures en K,
vmr sans unite. Taug/taur en sortie : (nlay, 112) pour SW (g-points reduits 224->112),
taug/fracs LW : (nlay+1, 140).
"""
import ctypes
import numpy as np

MXLAY = 203
NGPTSW = 112   # ngptsw apres reduction par rrtmg_sw_ini (224 -> 112)
NGPTLW = 140


def dbl_data(path):
    """On compile avec -DRWORDSIZE=8 (kind_rb = double) -> il faut lire les
    fichiers de donnees *_DBL (RRTMG_SW_DATA_DBL / RRTMG_LW_DATA_DBL, 2x plus
    gros car doubles). Si le _DBL existe, on le prend, sinon le fichier de base."""
    import os
    dbl = path + "_DBL"
    return dbl if os.path.exists(dbl) else path


def _buf(v, n=MXLAY):
    """np array 1D -> buffer c_double de taille MXLAY (complete par des zeros)."""
    b = np.zeros(n, dtype=np.float64)
    v = np.asarray(v, dtype=np.float64).ravel()
    b[: v.size] = v
    return b


class RRTMG_Taumol:
    def __init__(self, so_path, sw_data, lw_data):
        lib = ctypes.CDLL(so_path)
        lib.pinn_sw_init.argtypes = [ctypes.c_char_p]
        lib.pinn_sw_init.restype = None
        lib.pinn_lw_init.argtypes = [ctypes.c_char_p]
        lib.pinn_lw_init.restype = None
        dp = ctypes.POINTER(ctypes.c_double)
        lib.pinn_sw_taumol.argtypes = [ctypes.c_int] + [dp] * 11
        lib.pinn_sw_taumol.restype = None
        lib.pinn_lw_taumol.argtypes = [ctypes.c_int] + [dp] * 10
        lib.pinn_lw_taumol.restype = None
        self.lib = lib
        lib.pinn_sw_init(dbl_data(sw_data).encode())
        lib.pinn_lw_init(dbl_data(lw_data).encode())

    def taumol_sw(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
        """taumol_sw : pas de cossza en entree (les epaisseurs optiques n'en
        dependent pas ; la fonction source solaire est normalisee par prmu0 en aval)."""
        n = len(play)
        assert len(plev) == n + 1 and len(tlev) == n + 1
        taug = np.zeros((MXLAY, NGPTSW), dtype=np.float64, order="F")
        taur = np.zeros((MXLAY, NGPTSW), dtype=np.float64, order="F")
        self.lib.pinn_sw_taumol(
            n,
            _buf(play).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(plev, MXLAY + 1).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(tlay).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(tlev, MXLAY + 1).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            ctypes.c_double(tsfc),
            _buf(h2o).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(o3).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(co2).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(ch4).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(n2o).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(o2).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            taug.ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            taur.ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
        )
        return taug[:n, :].copy(), taur[:n, :].copy()

    def taumol_lw(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
        n = len(play)
        assert len(plev) == n + 1 and len(tlev) == n + 1
        taug = np.zeros((MXLAY + 1, NGPTLW), dtype=np.float64, order="F")
        fracs = np.zeros((MXLAY + 1, NGPTLW), dtype=np.float64, order="F")
        self.lib.pinn_lw_taumol(
            n,
            _buf(play).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(plev, MXLAY + 1).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(tlay).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(tlev, MXLAY + 1).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            ctypes.c_double(tsfc),
            _buf(h2o).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(o3).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(co2).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(ch4).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(n2o).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            _buf(o2).ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            taug.ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
            fracs.ctypes.data_as(ctypes.POINTER(ctypes.c_double)),
        )
        return taug[: n + 1, :].copy(), fracs[: n + 1, :].copy()
