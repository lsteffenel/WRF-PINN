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


def data_file(path):
    """Fichier de donnees RRTMG a lire : le conteneur compile WRF en RWORDSIZE=4
    (kind_rb = simple) -> fichier SIMPLE (pas _DBL), et comme les RRTMG_*_DATA
    sont big-endian, build.sh produit une copie LE natif '<path>.le' qu'on prefere."""
    import os
    le = path + ".le"
    return le if os.path.exists(le) else path


def _buf(v, n=MXLAY):
    """np array 1D -> buffer c_float (kind_rb=simple, RWORDSIZE=4) de taille n."""
    b = np.zeros(n, dtype=np.float32)
    v = np.asarray(v, dtype=np.float32).ravel()
    b[: v.size] = v
    return b


class RRTMG_Taumol:
    def __init__(self, so_path, sw_data, lw_data):
        lib = ctypes.CDLL(so_path)
        lib.pinn_sw_init.argtypes = [ctypes.c_char_p]
        lib.pinn_sw_init.restype = None
        lib.pinn_lw_init.argtypes = [ctypes.c_char_p]
        lib.pinn_lw_init.restype = None
        fp = ctypes.POINTER(ctypes.c_float)
        lib.pinn_sw_taumol.argtypes = [ctypes.c_int] + [fp] * 11
        lib.pinn_sw_taumol.restype = None
        lib.pinn_lw_taumol.argtypes = [ctypes.c_int] + [fp] * 10
        lib.pinn_lw_taumol.restype = None
        # signature Fortran: (nlay, play,plev,tlay,tlev, tsfc, h2o..o2) ; sorties via variables bind(C)
        lib.pinn_sw_debug.argtypes = [ctypes.c_int] + [fp] * 4 + [ctypes.c_float] + [fp] * 6
        lib.pinn_sw_debug.restype = None
        # NB: tsfc est un scalaire bind(C) SANS value -> by reference : argtype fp
        # (ctypes passe alors le c_float en byref). Ne PAS mettre c_float ici.
        lib.pinn_sw_sfluxzen.argtypes = [ctypes.c_int] + [fp] * 11
        lib.pinn_sw_sfluxzen.restype = None
        self.lib = lib
        lib.pinn_sw_init(data_file(sw_data).encode())
        lib.pinn_lw_init(data_file(lw_data).encode())

    def taumol_sw(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
        """taumol_sw : pas de cossza en entree (les epaisseurs optiques n'en
        dependent pas ; la fonction source solaire est normalisee par prmu0 en aval)."""
        n = len(play)
        assert len(plev) == n + 1 and len(tlev) == n + 1
        taug = np.zeros((MXLAY, NGPTSW), dtype=np.float32, order="F")
        taur = np.zeros((MXLAY, NGPTSW), dtype=np.float32, order="F")
        fp = ctypes.POINTER(ctypes.c_float)
        self.lib.pinn_sw_taumol(
            n,
            _buf(play).ctypes.data_as(fp),
            _buf(plev, MXLAY + 1).ctypes.data_as(fp),
            _buf(tlay).ctypes.data_as(fp),
            _buf(tlev, MXLAY + 1).ctypes.data_as(fp),
            ctypes.c_float(tsfc),
            _buf(h2o).ctypes.data_as(fp),
            _buf(o3).ctypes.data_as(fp),
            _buf(co2).ctypes.data_as(fp),
            _buf(ch4).ctypes.data_as(fp),
            _buf(n2o).ctypes.data_as(fp),
            _buf(o2).ctypes.data_as(fp),
            taug.ctypes.data_as(fp),
            taur.ctypes.data_as(fp),
        )
        return taug[:n, :].astype(np.float64), taur[:n, :].astype(np.float64)

    def taumol_lw(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
        n = len(play)
        assert len(plev) == n + 1 and len(tlev) == n + 1
        taug = np.zeros((MXLAY + 1, NGPTLW), dtype=np.float32, order="F")
        fracs = np.zeros((MXLAY + 1, NGPTLW), dtype=np.float32, order="F")
        fp = ctypes.POINTER(ctypes.c_float)
        self.lib.pinn_lw_taumol(
            n,
            _buf(play).ctypes.data_as(fp),
            _buf(plev, MXLAY + 1).ctypes.data_as(fp),
            _buf(tlay).ctypes.data_as(fp),
            _buf(tlev, MXLAY + 1).ctypes.data_as(fp),
            ctypes.c_float(tsfc),
            _buf(h2o).ctypes.data_as(fp),
            _buf(o3).ctypes.data_as(fp),
            _buf(co2).ctypes.data_as(fp),
            _buf(ch4).ctypes.data_as(fp),
            _buf(n2o).ctypes.data_as(fp),
            _buf(o2).ctypes.data_as(fp),
            taug.ctypes.data_as(fp),
            fracs.ctypes.data_as(fp),
        )
        return taug[: n + 1, :].astype(np.float64), fracs[: n + 1, :].astype(np.float64)

    def sw_sfluxzen(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
        """sfluxzen (fonction source solaire par g-point, intent(out) de taumol_sw).
        Ne depend pas du profil (sfluxref des tables) : a appeler une seule fois,
        puis a injecter dans le shell du .so rad_pinn (pinn_sfluxzen_ext)."""
        n = len(play)
        fp = ctypes.POINTER(ctypes.c_float)
        sfluxzen = np.zeros(NGPTSW, dtype=np.float32)
        self.lib.pinn_sw_sfluxzen(
            n,
            _buf(play).ctypes.data_as(fp), _buf(plev, MXLAY + 1).ctypes.data_as(fp),
            _buf(tlay).ctypes.data_as(fp), _buf(tlev, MXLAY + 1).ctypes.data_as(fp),
            ctypes.c_float(tsfc),
            _buf(h2o).ctypes.data_as(fp), _buf(o3).ctypes.data_as(fp), _buf(co2).ctypes.data_as(fp),
            _buf(ch4).ctypes.data_as(fp), _buf(n2o).ctypes.data_as(fp), _buf(o2).ctypes.data_as(fp),
            sfluxzen.ctypes.data_as(fp),
        )
        return sfluxzen.astype(np.float64)

    def sw_debug(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2):
        """Intermediaires de inatm_sw + setcoef_sw, lus via les variables bind(C)
        pinn_dbg_* : laytrop, jp, pavel, colh2o, coldry."""
        n = len(play)
        fp = ctypes.POINTER(ctypes.c_float)
        self.lib.pinn_sw_debug(
            n,
            _buf(play).ctypes.data_as(fp), _buf(plev, MXLAY + 1).ctypes.data_as(fp),
            _buf(tlay).ctypes.data_as(fp), _buf(tlev, MXLAY + 1).ctypes.data_as(fp),
            ctypes.c_float(tsfc),
            _buf(h2o).ctypes.data_as(fp), _buf(o3).ctypes.data_as(fp), _buf(co2).ctypes.data_as(fp),
            _buf(ch4).ctypes.data_as(fp), _buf(n2o).ctypes.data_as(fp), _buf(o2).ctypes.data_as(fp),
        )
        laytrop = ctypes.c_int.in_dll(self.lib, "pinn_dbg_laytrop").value
        jp = np.array((ctypes.c_int * MXLAY).in_dll(self.lib, "pinn_dbg_jp")[:n], dtype=np.int64)
        pavel = np.array((ctypes.c_float * MXLAY).in_dll(self.lib, "pinn_dbg_pavel")[:n], dtype=np.float64)
        colh2o = np.array((ctypes.c_float * MXLAY).in_dll(self.lib, "pinn_dbg_colh2o")[:n], dtype=np.float64)
        coldry = np.array((ctypes.c_float * MXLAY).in_dll(self.lib, "pinn_dbg_coldry")[:n], dtype=np.float64)
        return laytrop, jp, pavel, colh2o, coldry


class RRTMG_Rad:
    """Transfert radiatif complet clear-sky via librrtmg_rad_{ref,pinn}.so :
    pinn_sw_rad (inatm_sw + setcoef_sw + spcvmc_sw) et pinn_lw_rad (inatm + setcoef
    + rtrnmc avec taug/fracs fournis en entree).

    - .so "ref"  : spcvmc_sw appelle le vrai taumol_sw -> flux de reference.
    - .so "pinn" : taumol_sw est le shell pinn_taumol_shell ; appeler set_sw_ext()
      avant pinn_sw_rad pour injecter taug/taur du PINN + sfluxzen (lu une fois
      via RRTMG_Taumol.sw_sfluxzen sur le .so taumol de reference).
    """

    def __init__(self, so_path, sw_data, lw_data):
        lib = ctypes.CDLL(so_path)
        lib.pinn_rad_init.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        lib.pinn_rad_init.restype = None
        fp = ctypes.POINTER(ctypes.c_float)
        # tsfc by ref (pas value dans le Fortran) -> fp ; cossza/alb/emis ont value -> c_float
        lib.pinn_sw_rad.argtypes = ([ctypes.c_int] + [fp] * 11
                                    + [ctypes.c_float, ctypes.c_float] + [fp] * 3)
        lib.pinn_sw_rad.restype = None
        lib.pinn_lw_rad.argtypes = ([ctypes.c_int] + [fp] * 11
                                    + [ctypes.c_float] + [fp] * 2 + [fp] * 3)
        lib.pinn_lw_rad.restype = None
        self.lib = lib
        lib.pinn_rad_init(data_file(sw_data).encode(), data_file(lw_data).encode())

    def set_sw_ext(self, taug, taur, sfluxzen):
        """Ecrit les buffers bind(C) du shell (so rad_pinn uniquement) :
        taug/taur (nlay, NGPTSW) -> pinn_taug_ext/pinn_taur_ext (MXLAY, NGPTSW)
        col-major ; sfluxzen (NGPTSW,) -> pinn_sfluxzen_ext."""
        n = taug.shape[0]
        bt = np.zeros((MXLAY, NGPTSW), dtype=np.float32, order="F")
        br = np.zeros((MXLAY, NGPTSW), dtype=np.float32, order="F")
        bt[:n, :] = taug
        br[:n, :] = taur
        at = (ctypes.c_float * (MXLAY * NGPTSW)).in_dll(self.lib, "pinn_taug_ext")
        ar = (ctypes.c_float * (MXLAY * NGPTSW)).in_dll(self.lib, "pinn_taur_ext")
        at[:] = bt.ravel(order="F")
        ar[:] = br.ravel(order="F")
        asf = (ctypes.c_float * NGPTSW).in_dll(self.lib, "pinn_sfluxzen_ext")
        asf[:] = np.asarray(sfluxzen, dtype=np.float32)

    def sw_rad(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2,
               cossza, alb=0.07):
        """-> (fbbfd, fbbfu, swhr) : flux down/up (n+1, W/m2, index 0 = sol) et
        heating rate SW (n, K/jour)."""
        n = len(play)
        assert len(plev) == n + 1 and len(tlev) == n + 1
        fp = ctypes.POINTER(ctypes.c_float)
        fbbfd = np.zeros(MXLAY + 1, dtype=np.float32)
        fbbfu = np.zeros(MXLAY + 1, dtype=np.float32)
        swhr = np.zeros(MXLAY, dtype=np.float32)
        self.lib.pinn_sw_rad(
            n,
            _buf(play).ctypes.data_as(fp), _buf(plev, MXLAY + 1).ctypes.data_as(fp),
            _buf(tlay).ctypes.data_as(fp), _buf(tlev, MXLAY + 1).ctypes.data_as(fp),
            ctypes.c_float(tsfc),
            _buf(h2o).ctypes.data_as(fp), _buf(o3).ctypes.data_as(fp), _buf(co2).ctypes.data_as(fp),
            _buf(ch4).ctypes.data_as(fp), _buf(n2o).ctypes.data_as(fp), _buf(o2).ctypes.data_as(fp),
            ctypes.c_float(cossza), ctypes.c_float(alb),
            fbbfd.ctypes.data_as(fp), fbbfu.ctypes.data_as(fp), swhr.ctypes.data_as(fp),
        )
        return fbbfd[: n + 1].astype(np.float64), fbbfu[: n + 1].astype(np.float64), swhr[:n].astype(np.float64)

    def lw_rad(self, play, plev, tlay, tlev, tsfc, h2o, o3, co2, ch4, n2o, o2,
               emis, taug, fracs):
        """taug/fracs (n+1, NGPTLW) fournis (ref ou PINN) -> (totuflux, totdflux, htr)
        : flux up/down (n+1, W/m2, index 0 = sol) et heating rate LW (n+1, K/jour)."""
        n = len(play)
        assert taug.shape == (n + 1, NGPTLW) and fracs.shape == (n + 1, NGPTLW)
        fp = ctypes.POINTER(ctypes.c_float)
        taut = np.zeros((MXLAY + 1, NGPTLW), dtype=np.float32, order="F")
        fr = np.zeros((MXLAY + 1, NGPTLW), dtype=np.float32, order="F")
        taut[: n + 1, :] = taug
        fr[: n + 1, :] = fracs
        totuflux = np.zeros(MXLAY + 1, dtype=np.float32)
        totdflux = np.zeros(MXLAY + 1, dtype=np.float32)
        htr = np.zeros(MXLAY + 1, dtype=np.float32)
        self.lib.pinn_lw_rad(
            n,
            _buf(play).ctypes.data_as(fp), _buf(plev, MXLAY + 1).ctypes.data_as(fp),
            _buf(tlay).ctypes.data_as(fp), _buf(tlev, MXLAY + 1).ctypes.data_as(fp),
            ctypes.c_float(tsfc),
            _buf(h2o).ctypes.data_as(fp), _buf(o3).ctypes.data_as(fp), _buf(co2).ctypes.data_as(fp),
            _buf(ch4).ctypes.data_as(fp), _buf(n2o).ctypes.data_as(fp), _buf(o2).ctypes.data_as(fp),
            ctypes.c_float(emis),
            taut.ravel(order="F").ctypes.data_as(fp), fr.ravel(order="F").ctypes.data_as(fp),
            totuflux.ctypes.data_as(fp), totdflux.ctypes.data_as(fp), htr.ctypes.data_as(fp),
        )
        return totuflux[: n + 1].astype(np.float64), totdflux[: n + 1].astype(np.float64), htr[: n + 1].astype(np.float64)
