! Wrapper C (bind(C)) au-dessus des routines RRTMG de WRF v4.6.1 :
!   pinn_sw_init / pinn_sw_taumol  -> taumol_sw  (RRTMG_SW, 112 g-points apres reduction)
!   pinn_lw_init / pinn_lw_taumol  -> taumol     (RRTMG_LW, 140 g-points)
! Compile avec les "core" extraits par extract_sources.sh (voir build.sh).
! Cote Python : ctypes, tableaux en column-major (Fortran), buffers de taille MXLAY.
module pinn_taumol_api
  use iso_c_binding
  use parkind, only: im => kind_im, rb => kind_rb
  use parrrsw, only: sw_mxlay => mxlay, ngptsw, sw_mxmol => mxmol, jpband, rrsw_scon
  use parrrtm, only: lw_mxlay => mxlay, ngptlw, nbndlw, lw_mxmol => mxmol
  use rrtmg_sw_rad,    only: inatm_sw
  use rrtmg_sw_setcoef, only: setcoef_sw
  use rrtmg_sw_taumol,  only: taumol_sw
  use rrtmg_sw_init,    only: rrtmg_sw_ini
  use rrtmg_lw_rad,    only: inatm
  use rrtmg_lw_setcoef, only: setcoef
  use rrtmg_lw_taumol,  only: taumol
  use rrtmg_lw_init,    only: rrtmg_lw_ini
  implicit none

  ! loaders de tables d'absorption (extraits de la partie WRF, stub dm local)
  external sw_kgb16, sw_kgb17, sw_kgb18, sw_kgb19, sw_kgb20, sw_kgb21, sw_kgb22, &
           sw_kgb23, sw_kgb24, sw_kgb25, sw_kgb26, sw_kgb27, sw_kgb28, sw_kgb29
  external lw_kgb01, lw_kgb02, lw_kgb03, lw_kgb04, lw_kgb05, lw_kgb06, lw_kgb07, lw_kgb08, &
           lw_kgb09, lw_kgb10, lw_kgb11, lw_kgb12, lw_kgb13, lw_kgb14, lw_kgb15, lw_kgb16

  real(rb), parameter :: CPDAIR = 1004.6_rb   ! comme WRF (module_model_constants: cp)

contains

  !--------------------------------------------------------------------------
  subroutine c_to_f_string(cstr, fstr)
    character(kind=c_char), intent(in)  :: cstr(*)
    character(len=*),       intent(out) :: fstr
    integer :: i
    fstr = ' '
    do i = 1, len(fstr)
      if (cstr(i) == c_null_char) exit
      fstr(i:i) = cstr(i)
    end do
  end subroutine c_to_f_string

  !--------------------------------------------------------------------------
  subroutine pinn_sw_init(c_datafile) bind(C, name="pinn_sw_init")
    character(kind=c_char), intent(in) :: c_datafile(*)
    character(len=512) :: fname
    call c_to_f_string(c_datafile, fname)
    ! unite fixe 77 : gfortran 4.8 (CentOS 7) ne connait pas newunit= (F2008)
    open(77, file=trim(fname), form='unformatted', status='old', action='read')
    call sw_kgb16(77); call sw_kgb17(77); call sw_kgb18(77); call sw_kgb19(77)
    call sw_kgb20(77); call sw_kgb21(77); call sw_kgb22(77); call sw_kgb23(77)
    call sw_kgb24(77); call sw_kgb25(77); call sw_kgb26(77); call sw_kgb27(77)
    call sw_kgb28(77); call sw_kgb29(77)
    close(77)
    call rrtmg_sw_ini(CPDAIR)
  end subroutine pinn_sw_init

  !--------------------------------------------------------------------------
  subroutine pinn_lw_init(c_datafile) bind(C, name="pinn_lw_init")
    character(kind=c_char), intent(in) :: c_datafile(*)
    character(len=512) :: fname
    call c_to_f_string(c_datafile, fname)
    open(77, file=trim(fname), form='unformatted', status='old', action='read')
    call lw_kgb01(77); call lw_kgb02(77); call lw_kgb03(77); call lw_kgb04(77)
    call lw_kgb05(77); call lw_kgb06(77); call lw_kgb07(77); call lw_kgb08(77)
    call lw_kgb09(77); call lw_kgb10(77); call lw_kgb11(77); call lw_kgb12(77)
    call lw_kgb13(77); call lw_kgb14(77); call lw_kgb15(77); call lw_kgb16(77)
    close(77)
    call rrtmg_lw_ini(CPDAIR)
  end subroutine pinn_lw_init

  !--------------------------------------------------------------------------
  ! Une colonne atmospherique -> taug/taur (nlay x ngptsw), clear-sky, sans aerosol.
  ! Entrees (1D, taille max sw_mxlay, les nlay premieres sont lues) :
  !   play(nlay) pressions couches (hPa), plev(0:nlay) niveaux, tlay/tlev temperatures (K),
  !   tsfc, vmr h2o/o3/co2/ch4/n2o/o2 (taumol_sw ne prend pas le cosinus zenithal)
  subroutine pinn_sw_taumol(nlay, play, plev, tlay, tlev, tsfc, &
                            h2o, o3, co2, ch4, n2o, o2, taug, taur) &
       bind(C, name="pinn_sw_taumol")
    integer(c_int), value, intent(in) :: nlay
    real(c_float), intent(in)  :: play(*), plev(*), tlay(*), tlev(*), tsfc
    real(c_float), intent(in)  :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
    real(c_float), intent(out) :: taug(*), taur(*)   ! buffers sw_mxlay*ngptsw (col-major)

    integer(im) :: n, nlayers, laytrop, layswtch, laylow, ig
    integer(im) :: jp(sw_mxlay), jt(sw_mxlay), jt1(sw_mxlay)
    integer(im) :: indself(sw_mxlay), indfor(sw_mxlay)
    integer(im) :: inflag, iceflag, liqflag
    real(rb) :: play_l(1, sw_mxlay), plev_l(1, 0:sw_mxlay), tlay_l(1, sw_mxlay), tlev_l(1, 0:sw_mxlay)
    real(rb) :: tsfc_l(1), h2o_l(1, sw_mxlay), o3_l(1, sw_mxlay), co2_l(1, sw_mxlay)
    real(rb) :: ch4_l(1, sw_mxlay), n2o_l(1, sw_mxlay), o2_l(1, sw_mxlay)
    real(rb) :: cldfmcl(ngptsw, 1, sw_mxlay), taucmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: ssacmcl(ngptsw, 1, sw_mxlay), asmcmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: fsfcmcl(ngptsw, 1, sw_mxlay), ciwpmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: clwpmcl(ngptsw, 1, sw_mxlay), cswpmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: reicmcl(1, sw_mxlay), relqmcl(1, sw_mxlay), resnmcl(1, sw_mxlay)
    real(rb) :: tauaer(1, sw_mxlay, 14), ssaaer(1, sw_mxlay, 14), asmaer(1, sw_mxlay, 14)
    real(rb) :: pavel(sw_mxlay), pz(0:sw_mxlay), pdp(sw_mxlay), tavel(sw_mxlay), tz(0:sw_mxlay)
    real(rb) :: tbound, coldry(sw_mxlay), wkl(sw_mxmol, sw_mxlay)
    real(rb) :: adjflux(jpband), solvar(jpband)
    real(rb) :: cldfmc(ngptsw, sw_mxlay), taucmc(ngptsw, sw_mxlay), ssacmc(ngptsw, sw_mxlay)
    real(rb) :: asmcmc(ngptsw, sw_mxlay), fsfcmc(ngptsw, sw_mxlay)
    real(rb) :: ciwpmc(ngptsw, sw_mxlay), clwpmc(ngptsw, sw_mxlay), cswpmc(ngptsw, sw_mxlay)
    real(rb) :: reicmc(sw_mxlay), relqmc(sw_mxlay), resnmc(sw_mxlay)
    real(rb) :: taua(sw_mxlay, 14), ssaa(sw_mxlay, 14), asma(sw_mxlay, 14)
    real(rb) :: colh2o(sw_mxlay), colco2(sw_mxlay), colch4(sw_mxlay), colo2(sw_mxlay)
    real(rb) :: colo3(sw_mxlay), colmol(sw_mxlay), coln2o(sw_mxlay), co2mult(sw_mxlay)
    real(rb) :: fac00(sw_mxlay), fac01(sw_mxlay), fac10(sw_mxlay), fac11(sw_mxlay)
    real(rb) :: selffac(sw_mxlay), selffrac(sw_mxlay), forfac(sw_mxlay), forfrac(sw_mxlay)
    real(rb) :: sfluxzen_l(ngptsw), taug2(sw_mxlay, ngptsw), taur2(sw_mxlay, ngptsw)

    n = nlay
    play_l(1, 1:n) = play(1:n);  plev_l(1, 0:n) = plev(0:n)
    tlay_l(1, 1:n) = tlay(1:n);  tlev_l(1, 0:n) = tlev(0:n)
    tsfc_l(1) = tsfc
    h2o_l(1, 1:n) = h2o(1:n); o3_l(1, 1:n) = o3(1:n); co2_l(1, 1:n) = co2(1:n)
    ch4_l(1, 1:n) = ch4(1:n); n2o_l(1, 1:n) = n2o(1:n); o2_l(1, 1:n) = o2(1:n)
    cldfmcl = 0._rb; taucmcl = 0._rb; ssacmcl = 0._rb; asmcmcl = 0._rb; fsfcmcl = 0._rb
    ciwpmcl = 0._rb; clwpmcl = 0._rb; cswpmcl = 0._rb
    reicmcl = 0._rb; relqmcl = 0._rb; resnmcl = 0._rb
    tauaer = 0._rb; ssaaer = 0._rb; asmaer = 0._rb

    call inatm_sw(1, n, 0, 10, play_l, plev_l, tlay_l, tlev_l, tsfc_l, &
                  h2o_l, o3_l, co2_l, ch4_l, n2o_l, o2_l, &
                  1.0_rb, 1, rrsw_scon, 2, 0, 0, &
                  cldfmcl, taucmcl, ssacmcl, asmcmcl, fsfcmcl, ciwpmcl, clwpmcl, cswpmcl, &
                  reicmcl, relqmcl, resnmcl, tauaer, ssaaer, asmaer, &
                  nlayers, pavel, pz, pdp, tavel, tz, tbound, coldry, wkl, &
                  adjflux, solvar, inflag, iceflag, liqflag, &
                  cldfmc, taucmc, ssacmc, asmcmc, fsfcmc, ciwpmc, clwpmc, cswpmc, &
                  reicmc, relqmc, resnmc, taua, ssaa, asma)

    call setcoef_sw(nlayers, pavel, tavel, pz, tz, tbound, coldry, wkl, &
                    laytrop, layswtch, laylow, jp, jt, jt1, &
                    co2mult, colch4, colco2, colh2o, colmol, coln2o, &
                    colo2, colo3, fac00, fac01, fac10, fac11, &
                    selffac, selffrac, indself, forfac, forfrac, indfor)

    ! NB: taumol_sw ne prend PAS le cosinus zenithal : sfluxzen est intent(out)
    ! (fonction source solaire normalisee par g-point ; prmu0 n'intervient que
    ! dans le flux, en aval, cf. spcvmc_sw: zincflx = adjflux*zsflxzen*prmu0)
    call taumol_sw(nlayers, colh2o, colco2, colch4, colo2, colo3, colmol, &
                   laytrop, jp, jt, jt1, fac00, fac01, fac10, fac11, &
                   selffac, selffrac, indself, forfac, forfrac, indfor, &
                   sfluxzen_l, taug2, taur2)

    ! copie par g-point avec le stride du buffer C (sw_mxlay), PAS n :
    ! le buffer Python est (MXLAY, NGPTSW) en col-major -> offset lay + (ig-1)*sw_mxlay
    do ig = 1, ngptsw
      taug(1+(ig-1)*sw_mxlay : n+(ig-1)*sw_mxlay) = taug2(1:n, ig)
      taur(1+(ig-1)*sw_mxlay : n+(ig-1)*sw_mxlay) = taur2(1:n, ig)
    end do
  end subroutine pinn_sw_taumol

  !--------------------------------------------------------------------------
  ! Une colonne atmospherique -> taug/fracs LW (nlay+1 x ngptlw), clear-sky.
  subroutine pinn_lw_taumol(nlay, play, plev, tlay, tlev, tsfc, &
                            h2o, o3, co2, ch4, n2o, o2, taug, fracs) &
       bind(C, name="pinn_lw_taumol")
    integer(c_int), value, intent(in) :: nlay
    real(c_float), intent(in)  :: play(*), plev(*), tlay(*), tlev(*), tsfc
    real(c_float), intent(in)  :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
    real(c_float), intent(out) :: taug(*), fracs(*)  ! buffers (lw_mxlay+1)*ngptlw (col-major)

    integer(im) :: n, nlayers, laytrop, istart, ig
    integer(im) :: jp(lw_mxlay), jt(lw_mxlay), jt1(lw_mxlay)
    integer(im) :: indself(lw_mxlay), indfor(lw_mxlay), indminor(lw_mxlay)
    integer(im) :: inflag, iceflag, liqflag
    real(rb) :: play_l(1, lw_mxlay), plev_l(1, 0:lw_mxlay), tlay_l(1, lw_mxlay), tlev_l(1, 0:lw_mxlay)
    real(rb) :: tsfc_l(1), h2o_l(1, lw_mxlay), o3_l(1, lw_mxlay), co2_l(1, lw_mxlay)
    real(rb) :: ch4_l(1, lw_mxlay), n2o_l(1, lw_mxlay), o2_l(1, lw_mxlay)
    real(rb) :: cfc11_l(1, lw_mxlay), cfc12_l(1, lw_mxlay), cfc22_l(1, lw_mxlay), ccl4_l(1, lw_mxlay)
    real(rb) :: emis_l(1, nbndlw)
    real(rb) :: cldfmcl(ngptlw, 1, lw_mxlay), ciwpmcl(ngptlw, 1, lw_mxlay)
    real(rb) :: clwpmcl(ngptlw, 1, lw_mxlay), cswpmcl(ngptlw, 1, lw_mxlay)
    real(rb) :: relqmcl(1, lw_mxlay), reicmcl(1, lw_mxlay), resnmcl(1, lw_mxlay)
    real(rb) :: taucmcl(ngptlw, 1, lw_mxlay), tauaer(1, lw_mxlay, nbndlw)
    real(rb) :: pavel(lw_mxlay), pz(0:lw_mxlay), tavel(lw_mxlay), tz(0:lw_mxlay)
    real(rb) :: tbound, coldry(lw_mxlay), wkl(lw_mxmol, lw_mxlay), wbrodl(lw_mxlay)
    real(rb) :: wx_l(4, lw_mxlay+1), pwvcm, semiss(nbndlw)
    real(rb) :: cldfmc(ngptlw, lw_mxlay), taucmc(ngptlw, lw_mxlay)
    real(rb) :: ciwpmc(ngptlw, lw_mxlay), clwpmc(ngptlw, lw_mxlay), cswpmc(ngptlw, lw_mxlay)
    real(rb) :: reicmc(lw_mxlay), relqmc(lw_mxlay), resnmc(lw_mxlay)
    real(rb) :: taua(lw_mxlay, nbndlw)
    real(rb) :: planklay(lw_mxlay, nbndlw), planklev(0:lw_mxlay, nbndlw), plankbnd(nbndlw)
    real(rb) :: colh2o(lw_mxlay), colco2(lw_mxlay), colo3(lw_mxlay), coln2o(lw_mxlay)
    real(rb) :: colco(lw_mxlay), colch4(lw_mxlay), colo2(lw_mxlay), colbrd(lw_mxlay)
    real(rb) :: fac00(lw_mxlay), fac01(lw_mxlay), fac10(lw_mxlay), fac11(lw_mxlay)
    real(rb) :: selffac(lw_mxlay), selffrac(lw_mxlay), forfac(lw_mxlay), forfrac(lw_mxlay)
    real(rb) :: minorfrac(lw_mxlay), scaleminor(lw_mxlay), scaleminorn2(lw_mxlay)
    real(rb) :: rat_h2oco2(lw_mxlay), rat_h2oco2_1(lw_mxlay), rat_h2oo3(lw_mxlay), rat_h2oo3_1(lw_mxlay)
    real(rb) :: rat_h2on2o(lw_mxlay), rat_h2on2o_1(lw_mxlay), rat_h2och4(lw_mxlay), rat_h2och4_1(lw_mxlay)
    real(rb) :: rat_n2oco2(lw_mxlay), rat_n2oco2_1(lw_mxlay), rat_o3co2(lw_mxlay), rat_o3co2_1(lw_mxlay)
    real(rb) :: fracs2(lw_mxlay+1, ngptlw), taug2(lw_mxlay+1, ngptlw)

    n = nlay
    play_l(1, 1:n) = play(1:n);  plev_l(1, 0:n) = plev(0:n)
    tlay_l(1, 1:n) = tlay(1:n);  tlev_l(1, 0:n) = tlev(0:n)
    tsfc_l(1) = tsfc
    h2o_l(1, 1:n) = h2o(1:n); o3_l(1, 1:n) = o3(1:n); co2_l(1, 1:n) = co2(1:n)
    ch4_l(1, 1:n) = ch4(1:n); n2o_l(1, 1:n) = n2o(1:n); o2_l(1, 1:n) = o2(1:n)
    cfc11_l = 0._rb; cfc12_l = 0._rb; cfc22_l = 0._rb; ccl4_l = 0._rb
    emis_l(1, :) = 1._rb
    cldfmcl = 0._rb; ciwpmcl = 0._rb; clwpmcl = 0._rb; cswpmcl = 0._rb
    relqmcl = 0._rb; reicmcl = 0._rb; resnmcl = 0._rb
    taucmcl = 0._rb; tauaer = 0._rb

    call inatm(1, n, 0, 10, play_l, plev_l, tlay_l, tlev_l, tsfc_l, &
               h2o_l, o3_l, co2_l, ch4_l, n2o_l, o2_l, cfc11_l, cfc12_l, cfc22_l, ccl4_l, &
               emis_l, 2, 0, 0, &
               cldfmcl, taucmcl, ciwpmcl, clwpmcl, cswpmcl, reicmcl, relqmcl, resnmcl, tauaer, &
               nlayers, pavel, pz, tavel, tz, tbound, semiss, coldry, &
               wkl, wbrodl, wx_l, pwvcm, inflag, iceflag, liqflag, &
               cldfmc, taucmc, ciwpmc, clwpmc, cswpmc, reicmc, relqmc, resnmc, taua)

    istart = 1
    call setcoef(nlayers, istart, pavel, tavel, tz, tbound, semiss, &
                 coldry, wkl, wbrodl, &
                 laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                 colh2o, colco2, colo3, coln2o, colco, colch4, colo2, colbrd, &
                 fac00, fac01, fac10, fac11, &
                 rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                 rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                 rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                 selffac, selffrac, indself, forfac, forfrac, indfor, &
                 minorfrac, scaleminor, scaleminorn2, indminor)

    call taumol(nlayers, pavel, wx_l, coldry, &
                laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                colh2o, colco2, colo3, coln2o, colco, colch4, colo2, colbrd, &
                fac00, fac01, fac10, fac11, &
                rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                selffac, selffrac, indself, forfac, forfrac, indfor, &
                minorfrac, scaleminor, scaleminorn2, indminor, &
                fracs2, taug2)

    ! idem LW : buffer C (lw_mxlay+1, ngptlw) col-major, stride lw_mxlay+1
    do ig = 1, ngptlw
      taug(1+(ig-1)*(lw_mxlay+1) : (n+1)+(ig-1)*(lw_mxlay+1))  = taug2(1:n+1, ig)
      fracs(1+(ig-1)*(lw_mxlay+1) : (n+1)+(ig-1)*(lw_mxlay+1)) = fracs2(1:n+1, ig)
    end do
  end subroutine pinn_lw_taumol

  !--------------------------------------------------------------------------
  ! Debug : refait inatm_sw + setcoef_sw et sort les intermediaires pour
  ! diagnostiquer taumol_sw (laytrop, jp, pavel, colh2o, coldry par couche).
  subroutine pinn_sw_debug(nlay, play, plev, tlay, tlev, tsfc, &
                           h2o, o3, co2, ch4, n2o, o2, &
                           laytrop_o, jp_o, pavel_o, colh2o_o, coldry_o) &
       bind(C, name="pinn_sw_debug")
    integer(c_int), value, intent(in) :: nlay
    real(c_float), intent(in)  :: play(*), plev(*), tlay(*), tlev(*), tsfc
    real(c_float), intent(in)  :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
    integer(c_int), intent(out) :: laytrop_o
    integer(c_int), intent(out) :: jp_o(*)
    real(c_float), intent(out)  :: pavel_o(*), colh2o_o(*), coldry_o(*)

    integer(im) :: n, nlayers, laytrop, layswtch, laylow
    integer(im) :: jp(sw_mxlay), jt(sw_mxlay), jt1(sw_mxlay)
    integer(im) :: indself(sw_mxlay), indfor(sw_mxlay)
    integer(im) :: inflag, iceflag, liqflag
    real(rb) :: play_l(1, sw_mxlay), plev_l(1, 0:sw_mxlay), tlay_l(1, sw_mxlay), tlev_l(1, 0:sw_mxlay)
    real(rb) :: tsfc_l(1), h2o_l(1, sw_mxlay), o3_l(1, sw_mxlay), co2_l(1, sw_mxlay)
    real(rb) :: ch4_l(1, sw_mxlay), n2o_l(1, sw_mxlay), o2_l(1, sw_mxlay)
    real(rb) :: cldfmcl(ngptsw, 1, sw_mxlay), taucmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: ssacmcl(ngptsw, 1, sw_mxlay), asmcmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: fsfcmcl(ngptsw, 1, sw_mxlay), ciwpmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: clwpmcl(ngptsw, 1, sw_mxlay), cswpmcl(ngptsw, 1, sw_mxlay)
    real(rb) :: reicmcl(1, sw_mxlay), relqmcl(1, sw_mxlay), resnmcl(1, sw_mxlay)
    real(rb) :: tauaer(1, sw_mxlay, 14), ssaaer(1, sw_mxlay, 14), asmaer(1, sw_mxlay, 14)
    real(rb) :: pavel(sw_mxlay), pz(0:sw_mxlay), pdp(sw_mxlay), tavel(sw_mxlay), tz(0:sw_mxlay)
    real(rb) :: tbound, coldry(sw_mxlay), wkl(sw_mxmol, sw_mxlay)
    real(rb) :: adjflux(jpband), solvar(jpband)
    real(rb) :: cldfmc(ngptsw, sw_mxlay), taucmc(ngptsw, sw_mxlay), ssacmc(ngptsw, sw_mxlay)
    real(rb) :: asmcmc(ngptsw, sw_mxlay), fsfcmc(ngptsw, sw_mxlay)
    real(rb) :: ciwpmc(ngptsw, sw_mxlay), clwpmc(ngptsw, sw_mxlay), cswpmc(ngptsw, sw_mxlay)
    real(rb) :: reicmc(sw_mxlay), relqmc(sw_mxlay), resnmc(sw_mxlay)
    real(rb) :: taua(sw_mxlay, 14), ssaa(sw_mxlay, 14), asma(sw_mxlay, 14)
    real(rb) :: colh2o(sw_mxlay), colco2(sw_mxlay), colch4(sw_mxlay), colo2(sw_mxlay)
    real(rb) :: colo3(sw_mxlay), colmol(sw_mxlay), coln2o(sw_mxlay), co2mult(sw_mxlay)
    real(rb) :: fac00(sw_mxlay), fac01(sw_mxlay), fac10(sw_mxlay), fac11(sw_mxlay)
    real(rb) :: selffac(sw_mxlay), selffrac(sw_mxlay), forfac(sw_mxlay), forfrac(sw_mxlay)

    n = nlay
    play_l(1, 1:n) = play(1:n);  plev_l(1, 0:n) = plev(0:n)
    tlay_l(1, 1:n) = tlay(1:n);  tlev_l(1, 0:n) = tlev(0:n)
    tsfc_l(1) = tsfc
    h2o_l(1, 1:n) = h2o(1:n); o3_l(1, 1:n) = o3(1:n); co2_l(1, 1:n) = co2(1:n)
    ch4_l(1, 1:n) = ch4(1:n); n2o_l(1, 1:n) = n2o(1:n); o2_l(1, 1:n) = o2(1:n)
    cldfmcl = 0._rb; taucmcl = 0._rb; ssacmcl = 0._rb; asmcmcl = 0._rb; fsfcmcl = 0._rb
    ciwpmcl = 0._rb; clwpmcl = 0._rb; cswpmcl = 0._rb
    reicmcl = 0._rb; relqmcl = 0._rb; resnmcl = 0._rb
    tauaer = 0._rb; ssaaer = 0._rb; asmaer = 0._rb

    print *, '[pinn_sw_debug] avant inatm_sw n=', n
    call inatm_sw(1, n, 0, 10, play_l, plev_l, tlay_l, tlev_l, tsfc_l, &
                  h2o_l, o3_l, co2_l, ch4_l, n2o_l, o2_l, &
                  1.0_rb, 1, rrsw_scon, 2, 0, 0, &
                  cldfmcl, taucmcl, ssacmcl, asmcmcl, fsfcmcl, ciwpmcl, clwpmcl, cswpmcl, &
                  reicmcl, relqmcl, resnmcl, tauaer, ssaaer, asmaer, &
                  nlayers, pavel, pz, pdp, tavel, tz, tbound, coldry, wkl, &
                  adjflux, solvar, inflag, iceflag, liqflag, &
                  cldfmc, taucmc, ssacmc, asmcmc, fsfcmc, ciwpmc, clwpmc, cswpmc, &
                  reicmc, relqmc, resnmc, taua, ssaa, asma)
    print *, '[pinn_sw_debug] inatm_sw OK nlayers=', nlayers, 'pavel(1)=', pavel(1), 'coldry(1)=', coldry(1)

    print *, '[pinn_sw_debug] avant setcoef_sw'
    call setcoef_sw(nlayers, pavel, tavel, pz, tz, tbound, coldry, wkl, &
                    laytrop, layswtch, laylow, jp, jt, jt1, &
                    co2mult, colch4, colco2, colh2o, colmol, coln2o, &
                    colo2, colo3, fac00, fac01, fac10, fac11, &
                    selffac, selffrac, indself, forfac, forfrac, indfor)
    print *, '[pinn_sw_debug] setcoef_sw OK laytrop=', laytrop, 'jp(1)=', jp(1)

    laytrop_o = laytrop
    jp_o(1:n) = jp(1:n)
    pavel_o(1:n) = pavel(1:n)
    colh2o_o(1:n) = colh2o(1:n)
    coldry_o(1:n) = coldry(1:n)
  end subroutine pinn_sw_debug

end module pinn_taumol_api
