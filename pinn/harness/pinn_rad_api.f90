! Wrapper C (bind(C)) pour le TRANSFERT RADIATIF complet (clear-sky, sans aerosol),
! avec injection possible des epaisseurs optiques (modele PINN) :
!   pinn_rad_init        : charge les tables SW+LW (kgb + rrtmg_*_ini)
!   pinn_sw_rad          : inatm_sw + setcoef_sw + spcvmc_sw -> flux SW (W/m2) + swhr
!   pinn_lw_rad          : inatm + setcoef + rtrnmc(taut/fracs fournis) -> flux LW + htr
! Dans librrtmg_rad_ref.so, spcvmc_sw appelle le vrai taumol_sw (reference).
! Dans librrtmg_rad_pinn.so, taumol_sw est le shell pinn_taumol_shell (taug/taur
! lus dans pinn_taug_ext/pinn_taur_ext, remplis depuis Python via set_sw_ext).
! Compile avec les "core" extraits (build_rad.sh). Cote Python : ctypes, buffers
! column-major de taille sw_mxlay / sw_mxlay+1 (SW) et lw_mxlay+1 (LW).
module pinn_rad_api
  use iso_c_binding
  use parkind, only: im => kind_im, rb => kind_rb
  use parrrsw, only: sw_mxlay => mxlay, ngptsw, sw_mxmol => mxmol, jpband, nbndsw, rrsw_scon, jpb1, jpb2
  use parrrtm, only: lw_mxlay => mxlay, ngptlw, nbndlw, lw_mxmol => mxmol
  use rrsw_con, only: heatfac
  use rrtmg_sw_rad,    only: inatm_sw
  use rrtmg_sw_setcoef, only: setcoef_sw
  use rrtmg_sw_spcvmc,  only: spcvmc_sw
  use rrtmg_sw_init,    only: rrtmg_sw_ini
  use rrtmg_lw_rad,    only: inatm
  use rrtmg_lw_setcoef, only: setcoef
  use rrtmg_lw_rtrnmc,  only: rtrnmc
  use rrtmg_lw_init,    only: rrtmg_lw_ini
  implicit none

  external sw_kgb16, sw_kgb17, sw_kgb18, sw_kgb19, sw_kgb20, sw_kgb21, sw_kgb22, &
           sw_kgb23, sw_kgb24, sw_kgb25, sw_kgb26, sw_kgb27, sw_kgb28, sw_kgb29
  external lw_kgb01, lw_kgb02, lw_kgb03, lw_kgb04, lw_kgb05, lw_kgb06, lw_kgb07, lw_kgb08, &
           lw_kgb09, lw_kgb10, lw_kgb11, lw_kgb12, lw_kgb13, lw_kgb14, lw_kgb15, lw_kgb16

  real(rb), parameter :: CPDAIR = 1004.6_rb
  real(rb), parameter :: ZEPZEN = 1.0e-6_rb

contains

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
  subroutine pinn_rad_init(c_swdata, c_lwdata) bind(C, name="pinn_rad_init")
    character(kind=c_char), intent(in) :: c_swdata(*), c_lwdata(*)
    character(len=512) :: fname
    call c_to_f_string(c_swdata, fname)
    open(77, file=trim(fname), form='unformatted', status='old', action='read')
    call sw_kgb16(77); call sw_kgb17(77); call sw_kgb18(77); call sw_kgb19(77)
    call sw_kgb20(77); call sw_kgb21(77); call sw_kgb22(77); call sw_kgb23(77)
    call sw_kgb24(77); call sw_kgb25(77); call sw_kgb26(77); call sw_kgb27(77)
    call sw_kgb28(77); call sw_kgb29(77)
    close(77)
    call rrtmg_sw_ini(CPDAIR)
    call c_to_f_string(c_lwdata, fname)
    open(78, file=trim(fname), form='unformatted', status='old', action='read')
    call lw_kgb01(78); call lw_kgb02(78); call lw_kgb03(78); call lw_kgb04(78)
    call lw_kgb05(78); call lw_kgb06(78); call lw_kgb07(78); call lw_kgb08(78)
    call lw_kgb09(78); call lw_kgb10(78); call lw_kgb11(78); call lw_kgb12(78)
    call lw_kgb13(78); call lw_kgb14(78); call lw_kgb15(78); call lw_kgb16(78)
    close(78)
    call rrtmg_lw_ini(CPDAIR)
  end subroutine pinn_rad_init

  !--------------------------------------------------------------------------
  ! Transfert SW clear-sky : inatm_sw + setcoef_sw + spcvmc_sw.
  ! Entrees : profil colonne (comme pinn_sw_taumol) + cossza + alb (albedo).
  ! Sorties : fbbfd/fbbfu (0:n, W/m2, 0 = sol) buffers sw_mxlay+1, swhr (n, K/jour)
  ! buffer sw_mxlay. Dans le .so pinn, taumol_sw est le shell (taug/taur injectes).
  subroutine pinn_sw_rad(nlay, play, plev, tlay, tlev, tsfc, &
                         h2o, o3, co2, ch4, n2o, o2, cossza, alb, &
                         fbbfd, fbbfu, swhr) bind(C, name="pinn_sw_rad")
    integer(c_int), value, intent(in) :: nlay
    real(c_float), intent(in)  :: play(*), plev(*), tlay(*), tlev(*), tsfc
    real(c_float), intent(in)  :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
    real(c_float), value, intent(in) :: cossza, alb
    real(c_float), intent(out) :: fbbfd(*), fbbfu(*), swhr(*)

    integer(im) :: n, nlayers, laytrop, layswtch, laylow, ig, i
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
    real(rb) :: tauaer(1, sw_mxlay, nbndsw), ssaaer(1, sw_mxlay, nbndsw), asmaer(1, sw_mxlay, nbndsw)
    real(rb) :: pavel(sw_mxlay), pz(0:sw_mxlay), pdp(sw_mxlay), tavel(sw_mxlay), tz(0:sw_mxlay)
    real(rb) :: tbound, coldry(sw_mxlay), wkl(sw_mxmol, sw_mxlay)
    real(rb) :: adjflux(jpband), solvar(jpband)
    real(rb) :: cldfmc(ngptsw, sw_mxlay), taucmc(ngptsw, sw_mxlay), ssacmc(ngptsw, sw_mxlay)
    real(rb) :: asmcmc(ngptsw, sw_mxlay), fsfcmc(ngptsw, sw_mxlay)
    real(rb) :: ciwpmc(ngptsw, sw_mxlay), clwpmc(ngptsw, sw_mxlay), cswpmc(ngptsw, sw_mxlay)
    real(rb) :: reicmc(sw_mxlay), relqmc(sw_mxlay), resnmc(sw_mxlay)
    real(rb) :: taua(sw_mxlay, nbndsw), ssaa(sw_mxlay, nbndsw), asma(sw_mxlay, nbndsw)
    real(rb) :: colh2o(sw_mxlay), colco2(sw_mxlay), colch4(sw_mxlay), colo2(sw_mxlay)
    real(rb) :: colo3(sw_mxlay), colmol(sw_mxlay), coln2o(sw_mxlay), co2mult(sw_mxlay)
    real(rb) :: fac00(sw_mxlay), fac01(sw_mxlay), fac10(sw_mxlay), fac11(sw_mxlay)
    real(rb) :: selffac(sw_mxlay), selffrac(sw_mxlay), forfac(sw_mxlay), forfrac(sw_mxlay)
    real(rb) :: palbd(nbndsw), palbp(nbndsw), prmu0
    real(rb) :: zcldfmc(sw_mxlay, ngptsw), ztaucmc(sw_mxlay, ngptsw)
    real(rb) :: zasycmc(sw_mxlay, ngptsw), zomgcmc(sw_mxlay, ngptsw), ztaormc(sw_mxlay, ngptsw)
    real(rb) :: ztaua(sw_mxlay, nbndsw), zasya(sw_mxlay, nbndsw), zomga(sw_mxlay, nbndsw)
    real(rb) :: zbbfd(sw_mxlay+1), zbbfu(sw_mxlay+1), zbbcd(sw_mxlay+1), zbbcu(sw_mxlay+1)
    real(rb) :: zuvfd(sw_mxlay+1), zuvcd(sw_mxlay+1), znifd(sw_mxlay+1), znicd(sw_mxlay+1)
    real(rb) :: zbbfddir(sw_mxlay+1), zbbcddir(sw_mxlay+1)
    real(rb) :: zuvfddir(sw_mxlay+1), zuvcddir(sw_mxlay+1), znifddir(sw_mxlay+1), znicddir(sw_mxlay+1)
    real(rb) :: swnflx(sw_mxlay+1)

    n = nlay
    play_l(1, 1:n) = play(1:n);  plev_l(1, 0:n) = plev(1:n+1)
    tlay_l(1, 1:n) = tlay(1:n);  tlev_l(1, 0:n) = tlev(1:n+1)
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

    prmu0 = max(real(cossza, rb), ZEPZEN)
    palbd(:) = real(alb, rb)
    palbp(:) = real(alb, rb)
    zcldfmc = 0._rb; ztaucmc = 0._rb; ztaormc = 0._rb; zasycmc = 0._rb; zomgcmc = 1._rb
    ztaua = 0._rb; zasya = 0._rb; zomga = 1._rb

    ! istart/iend de spcvmc_sw = indices de BANDES (jpb1:jpb2 = 16:29), pas des g-points
    call spcvmc_sw(n, jpb1, jpb2, 1, 0, &
                   pavel, tavel, pz, tz, tbound, palbd, palbp, &
                   zcldfmc, ztaucmc, zasycmc, zomgcmc, ztaormc, &
                   ztaua, zasya, zomga, prmu0, coldry, wkl, adjflux, &
                   laytrop, layswtch, laylow, jp, jt, jt1, &
                   co2mult, colch4, colco2, colh2o, colmol, coln2o, colo2, colo3, &
                   fac00, fac01, fac10, fac11, &
                   selffac, selffrac, indself, forfac, forfrac, indfor, &
                   zbbfd, zbbfu, zbbcd, zbbcu, zuvfd, zuvcd, znifd, znicd, &
                   zbbfddir, zbbcddir, zuvfddir, zuvcddir, znifddir, znicddir)

    ! flux : jk=1..n+1, jk=1 = sol (bas). Buffer C fbbfd(1:n+1) -> C[0..n], C[0]=sol.
    do i = 1, n + 1
      fbbfd(i) = zbbfd(i)
      fbbfu(i) = zbbfu(i)
    end do
    ! heating rate couche i (1..n) comme rrtmg_sw : (swnflx(i+1)-swnflx(i))*heatfac/pdp(i)
    do i = 1, n + 1
      swnflx(i) = zbbfd(i) - zbbfu(i)
    end do
    do i = 1, n
      swhr(i) = (swnflx(i+1) - swnflx(i)) * heatfac / pdp(i)
    end do
  end subroutine pinn_sw_rad

  !--------------------------------------------------------------------------
  ! Transfert LW clear-sky : inatm + setcoef + rtrnmc avec taug/fracs FOURNIS
  ! (reference ou PINN) en entree. emis scalaire -> semiss(nbndlw).
  ! taug_in/fracs_in : buffers (lw_mxlay+1)*ngptlw col-major, index C k+(ig-1)*(lw_mxlay+1).
  ! Sorties : totuflux/totdflux (0:n, W/m2) buffers lw_mxlay+1, htr (0:n, K/jour).
  subroutine pinn_lw_rad(nlay, play, plev, tlay, tlev, tsfc, &
                         h2o, o3, co2, ch4, n2o, o2, emis, &
                         taug_in, fracs_in, totuflux, totdflux, htr) bind(C, name="pinn_lw_rad")
    integer(c_int), value, intent(in) :: nlay
    real(c_float), intent(in)  :: play(*), plev(*), tlay(*), tlev(*), tsfc
    real(c_float), intent(in)  :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
    real(c_float), value, intent(in) :: emis
    real(c_float), intent(in)  :: taug_in(*), fracs_in(*)
    real(c_float), intent(out) :: totuflux(*), totdflux(*), htr(*)

    integer(im) :: n, nlayers, laytrop, istart, ig, k
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
    real(rb) :: taut_l(lw_mxlay+1, ngptlw), fracs_l(lw_mxlay+1, ngptlw)
    real(rb) :: totuflux_l(0:lw_mxlay), totdflux_l(0:lw_mxlay), fnet_l(0:lw_mxlay), htr_l(0:lw_mxlay)
    real(rb) :: totuclfl_l(0:lw_mxlay), totdclfl_l(0:lw_mxlay), fnetc_l(0:lw_mxlay), htrc_l(0:lw_mxlay)
    real(rb) :: zcldfmc(ngptlw, lw_mxlay), ztaucmc(ngptlw, lw_mxlay)

    n = nlay
    play_l(1, 1:n) = play(1:n);  plev_l(1, 0:n) = plev(1:n+1)
    tlay_l(1, 1:n) = tlay(1:n);  tlev_l(1, 0:n) = tlev(1:n+1)
    tsfc_l(1) = tsfc
    h2o_l(1, 1:n) = h2o(1:n); o3_l(1, 1:n) = o3(1:n); co2_l(1, 1:n) = co2(1:n)
    ch4_l(1, 1:n) = ch4(1:n); n2o_l(1, 1:n) = n2o(1:n); o2_l(1, 1:n) = o2(1:n)
    cfc11_l = 0._rb; cfc12_l = 0._rb; cfc22_l = 0._rb; ccl4_l = 0._rb
    emis_l(1, :) = real(emis, rb)
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

    ! taug/fracs fournis (ref ou PINN) : buffer C (lw_mxlay+1, ngptlw) col-major
    ! C index (0-based) k+(ig-1)*(lw_mxlay+1) -> Fortran taut_l(k+1, ig)
    do ig = 1, ngptlw
      do k = 0, n
        taut_l(k+1, ig)  = taug_in(k + 1 + (ig-1)*(lw_mxlay+1))
        fracs_l(k+1, ig) = fracs_in(k + 1 + (ig-1)*(lw_mxlay+1))
      end do
    end do
    zcldfmc = 0._rb
    ztaucmc = 0._rb

    ! istart/iend de rtrnmc = bandes LW 1..nbndlw (16), pas les g-points
    call rtrnmc(n, 1, nbndlw, 0, pz, semiss, nbndlw, &
                zcldfmc, ztaucmc, planklay, planklev, plankbnd, &
                pwvcm, fracs_l, taut_l, &
                totuflux_l, totdflux_l, fnet_l, htr_l, &
                totuclfl_l, totdclfl_l, fnetc_l, htrc_l)

    do k = 0, n
      totuflux(k+1) = totuflux_l(k)
      totdflux(k+1) = totdflux_l(k)
      htr(k+1)      = htr_l(k)
    end do
  end subroutine pinn_lw_rad

end module pinn_rad_api
