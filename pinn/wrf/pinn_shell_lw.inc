      module module_pinn_shell_lw
! Shell de taumol (RRTMG LW) pour WRF (insere dans module_ra_rrtmg_lw.F par
! patch_wrf.sh, juste avant module rrtmg_lw_rad). Le driver appelle taumol par
! colonne : on remplace ce call par pinn_taumol_lw (sed), qui copie fracs/taug
! depuis les buffers PINN precalcules en batch (pinn_precompute_lw_tile, insere
! avant le j_loop du wrapper) si PINN_MODEL est defini, sinon appelle taumol_ref.
! NOTE: pas de use iso_c_binding ici (le pipeline cpp de WRF + gfortran 4.8 fait
! echouer c_char) et pas de double-slash (le cpp en mode C le prend pour un
! commentaire) : on declare les types C a la main (character(len=1)=c_char,
! real(4)=c_float, integer par defaut = c_int) et on construit la chaine NUL a
! la main.
! Les profils envoyes au PINN reproduisent EXACTEMENT le wrapper RRTMG_LWRAD :
! plev/play par deltap=4 hPa au-dessus du sommet (PAS de 1e-5 intermediaire qui
! rendrait plev negatif), tlev interpole depuis la table standard PPROF/TPROF
! avec shift sur tlev(kte), et o3 depuis la climatologie INIRAD quand
! o3input /= 2 (o33d vaut 0 avant le 1er appel radiation dans ce cas).
      use parkind, only: im => kind_im, rb => kind_rb
      use parrrtm, only: mxlay, ngptlw
      use rrtmg_lw_taumol, only: taumol_ref
      implicit none
      logical :: pinn_lw_on = .false.
      logical :: pinn_lw_ok = .false.
      logical :: pinn_lw_init_done = .false.
      logical :: pinn_lw_dbg = .false.
      integer(im) :: pinn_lw_col = 0
      real(4), allocatable :: pinn_lw_taug(:, :, :), pinn_lw_fracs(:, :, :)  ! (ncol, mxlay+1, ngptlw)
      real(rb), allocatable :: pinn_dbg_taug(:,:), pinn_dbg_fracs(:,:)  ! copie taumol_ref (PINN_DEBUG_CMP=1)
! Profil standard au-dessus du sommet (recopie de PPROF/TPROF du wrapper
! RRTMG_LWRAD, module module_ra_rrtmg_lw) pour tlev des couches tampon.
      integer, parameter :: pinn_nprof = 60
      real(rb) :: pinn_pprof(pinn_nprof), pinn_tprof(pinn_nprof)
      data pinn_pprof /1000.00,855.47,731.82,626.05,535.57,458.16,      &
                       391.94,335.29,286.83,245.38,209.91,179.57,         &
                       153.62,131.41,112.42,96.17,82.27,70.38,           &
                       60.21,51.51,44.06,37.69,32.25,27.59,              &
                       23.60,20.19,17.27,14.77,12.64,10.81,              &
                       9.25,7.91,6.77,5.79,4.95,4.24,                    &
                       3.63,3.10,2.65,2.27,1.94,1.66,                    &
                       1.42,1.22,1.04,0.89,0.76,0.65,                    &
                       0.56,0.48,0.41,0.35,0.30,0.26,                    &
                       0.22,0.19,0.16,0.14,0.12,0.10/
      data pinn_tprof /286.96,281.07,275.16,268.11,260.56,253.02,      &
                       245.62,238.41,231.57,225.91,221.72,217.79,         &
                       215.06,212.74,210.25,210.16,210.69,212.14,         &
                       213.74,215.37,216.82,217.94,219.03,220.18,         &
                       221.37,222.64,224.16,225.88,227.63,229.51,         &
                       231.50,233.73,236.18,238.78,241.60,244.44,         &
                       247.35,250.33,253.32,256.30,259.22,262.12,         &
                       264.80,266.50,267.59,268.44,268.69,267.76,         &
                       266.13,263.96,261.54,258.93,256.15,253.23,         &
                       249.89,246.67,243.48,240.25,236.66,233.86/
      interface
        function c_pinn_init(m) result(ok) bind(C, name="pinn_torch_init")
          integer :: ok
          character(len=1), intent(in) :: m(*)
        end function c_pinn_init
        function c_pinn_precompute_lw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                     h2o, o3, co2, ch4, n2o, o2, taug, fracs) &
             result(ok) bind(C, name="pinn_torch_precompute_lw")
          integer :: ok
          integer, value, intent(in) :: ncol, nlay
          real(4), intent(in) :: play(*), plev(*), tlay(*), tlev(*), tsfc(*)
          real(4), intent(in) :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
          real(4), intent(out) :: taug(*), fracs(*)
        end function c_pinn_precompute_lw
! INIRAD est une procedure du module module_ra_rrtmg_lw (symbole gfortran
! __module_ra_rrtmg_lw_MOD_inirad). On ne peut PAS faire use module_ra_rrtmg_lw
! ici (cycle : ce module use deja module_pinn_shell_lw via le wrapper), donc
! interface bind(C) vers le symbole mangle. Scalaires sans value = par adresse,
! compatible avec la declaration Fortran originale.
        subroutine pinn_inirad(o3prof, plev, kts, kte) &
             bind(C, name="__module_ra_rrtmg_lw_MOD_inirad")
          real(4) :: o3prof(*), plev(*)
          integer :: kts, kte
        end subroutine pinn_inirad
      end interface
      contains
      subroutine pinn_lw_init_once()
        character(len=1024) :: m
        character(len=1025) :: mc
        character(len=64) :: fl
        integer :: ios, ios2, fv, l, ok
        if (pinn_lw_init_done) return
        pinn_lw_init_done = .true.
        call get_environment_variable("PINN_MODEL", m, status=ios)
        if (ios /= 0 .or. len_trim(m) == 0) return
        if (trim(m) == "off" .or. trim(m) == "none" .or. trim(m) == "fortran") return
        fv = 1
        call get_environment_variable("PINN_LW", fl, status=ios2)
        if (ios2 == 0 .and. len_trim(fl) > 0) read(fl, *, iostat=ios2) fv
        if (fv == 0) then
          print *, "[PINN] LW desactive (PINN_LW=0), Fortran taumol"
          return
        end if
        call get_environment_variable("PINN_DEBUG_CMP", fl, status=ios2)
        if (ios2 == 0 .and. (trim(fl) == "1" .or. trim(fl) == "on")) pinn_lw_dbg = .true.
        l = len_trim(m)
        mc = achar(0)
        mc(1:l) = m(1:l)
        ok = c_pinn_init(mc)
        if (ok == 0) then
          print *, "[PINN] LW: echec chargement modele -> Fortran taumol_ref"
          return
        end if
        pinn_lw_on = .true.
        print *, "[PINN] LW: modele charge: ", trim(m)
      end subroutine pinn_lw_init_once
      subroutine pinn_precompute_lw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                    h2o, o3, co2, ch4, n2o, o2)
        integer(im), intent(in) :: ncol, nlay
        real(rb), intent(in) :: play(:,:), plev(:,:), tlay(:,:), tlev(:,:), tsfc(:)
        real(rb), intent(in) :: h2o(:,:), o3(:,:), co2(:,:), ch4(:,:), n2o(:,:), o2(:,:)
        real :: t0, t1
        integer :: ok
        call pinn_lw_init_once()
        pinn_lw_col = 0
        if (.not. pinn_lw_on) return
        if (allocated(pinn_lw_taug)) deallocate(pinn_lw_taug, pinn_lw_fracs)
        allocate(pinn_lw_taug(ncol, nlay + 1, ngptlw), pinn_lw_fracs(ncol, nlay + 1, ngptlw))
        call cpu_time(t0)
        ok = c_pinn_precompute_lw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                  h2o, o3, co2, ch4, n2o, o2, pinn_lw_taug, pinn_lw_fracs)
        pinn_lw_ok = (ok /= 0)
        call cpu_time(t1)
        print *, "[PINN] precompute_lw ncol=", ncol, " nlay=", nlay, " cpu=", t1 - t0, " s"
      end subroutine pinn_precompute_lw
      subroutine pinn_reset_lw()
        pinn_lw_col = 0
      end subroutine pinn_reset_lw
! Precompute batch de TOUTE la tuile (WRF appelle rrtmg_lw colonne par colonne,
! ncol=1 : le batch na de sens qu au niveau du wrapper RRTMG_LWRAD, avant sa
! boucle j). Reconstruction des profils 2D exactement comme le wrapper
! (p3d/p8w en hPa, qv*amdw, o3 via inirad si o3input /= 2, couches tampon
! deltap=4 hPa, tlev tampon depuis la table standard), enumeration j externe /
! i interne = meme ordre que les appels rrtmg_lw per-column, donc pinn_lw_col
! reste aligne avec l indice de colonne du batch.
      subroutine pinn_precompute_lw_tile(its, ite, jts, jte, kts, kte, nlayers, &
                                         p3d, p8w, t3d, t8w, qv3d, o33d, tsk, yr, o3input)
        integer(im), intent(in) :: its, ite, jts, jte, kts, kte, nlayers, yr, o3input
        real(rb), intent(in) :: p3d(:,:,:), p8w(:,:,:), t3d(:,:,:), t8w(:,:,:)
        real(rb), intent(in) :: qv3d(:,:,:), o33d(:,:,:), tsk(:,:)
        integer(im) :: nx, ny, ncol, nlay, nm, i, j, k, kk, L, LL, icol, ok, klev
        real(rb) :: co2, ch4, n2o, o2, t0, t1, wght, vark, vark1
        real(rb), allocatable :: play(:,:), plev(:,:), tlay(:,:), tlev(:,:), tsfc(:)
        real(rb), allocatable :: h2o(:,:), o3(:,:), c2(:,:), c4(:,:), n2(:,:), o22(:,:)
        real(rb), allocatable :: o3mmr(:), varint(:)
        call pinn_lw_init_once()
        pinn_lw_col = 0
        if (.not. pinn_lw_on) return
        nx = ite - its + 1
        ny = jte - jts + 1
        ncol = nx * ny
        nlay = nlayers
        nm = kte - kts + 1
        if (nlay < nm) then
          print *, "[PINN] tile: nlay < nm+1, fallback Fortran"
          pinn_lw_ok = .false.
          return
        end if
        co2 = (280._rb + 90._rb * exp(0.02_rb * real(yr - 2000, rb))) * 1.e-6_rb
        ch4 = 1774.e-9_rb
        n2o = 319.e-9_rb
        o2 = 0.209488_rb
        allocate(play(ncol,nlay), plev(ncol,nlay+1), tlay(ncol,nlay), tlev(ncol,nlay+1), tsfc(ncol))
        allocate(h2o(ncol,nlay), o3(ncol,nlay), c2(ncol,nlay), c4(ncol,nlay), n2(ncol,nlay), o22(ncol,nlay))
        allocate(o3mmr(nlay), varint(nlay+1))
        icol = 0
        do j = jts, jte
          do i = its, ite
            icol = icol + 1
            tsfc(icol) = tsk(i,j)
            plev(icol,1) = p8w(i,kts,j) / 100._rb
            tlev(icol,1) = t8w(i,kts,j)
            do k = kts, kte
              kk = k - kts + 1
              play(icol,kk) = p3d(i,k,j) / 100._rb
              plev(icol,kk+1) = p8w(i,k+1,j) / 100._rb
              tlay(icol,kk) = t3d(i,k,j)
              tlev(icol,kk+1) = t8w(i,k+1,j)
              h2o(icol,kk) = qv3d(i,k,j) * 1.607793_rb
              o3(icol,kk) = o33d(i,k,j) * 0.603461_rb
              c2(icol,kk) = co2
              c4(icol,kk) = ch4
              n2(icol,kk) = n2o
              o22(icol,kk) = o2
            end do
            ! couches tampon au-dessus du sommet du modele (cf wrapper) :
            ! nlay == nm+1 -> 1 niveau a plev=1e-5 ; nlay > nm+1 -> niveaux
            ! a deltap=4 hPa puis plev(nlay+1)=0 (cas LW).
            if (nlay >= nm + 1) then
              if (nlay == nm + 1) then
                play(icol,nm+1) = 0.5_rb * plev(icol,nm+1)
                plev(icol,nm+2) = 1.0e-5_rb
                tlay(icol,nm+1) = tlev(icol,nm+1)
                tlev(icol,nm+2) = tlev(icol,nm+1)
              else
                do L = nm + 1, nlay
                  plev(icol,L+1) = plev(icol,L) - 4.0_rb
                  play(icol,L) = 0.5_rb * (plev(icol,L) + plev(icol,L+1))
                end do
                plev(icol,nlay+1) = 0.0_rb
                play(icol,nlay) = 0.5_rb * (plev(icol,nlay) + plev(icol,nlay+1))
                ! tlev tampon : interpolation table standard + shift sur tlev(nm)
                do L = 1, nlay + 1
                  if (pinn_pprof(pinn_nprof) < plev(icol,L)) then
                    klev = 1
                    do LL = 2, pinn_nprof
                      if (pinn_pprof(LL) < plev(icol,L)) then
                        klev = LL - 1
                        exit
                      end if
                    end do
                  else
                    klev = pinn_nprof
                  end if
                  if (klev /= pinn_nprof) then
                    vark = pinn_tprof(klev)
                    vark1 = pinn_tprof(klev+1)
                    wght = (plev(icol,L) - pinn_pprof(klev)) / (pinn_pprof(klev+1) - pinn_pprof(klev))
                  else
                    vark = pinn_tprof(klev)
                    vark1 = pinn_tprof(klev)
                    wght = 0.0_rb
                  end if
                  varint(L) = wght * (vark1 - vark) + vark
                end do
                do L = nm + 1, nlay + 1
                  tlev(icol,L) = varint(L) + (tlev(icol,nm) - varint(nm))
                end do
                do L = nm + 1, nlay + 1
                  tlay(icol,L-1) = 0.5_rb * (tlev(icol,L) + tlev(icol,L-1))
                end do
              end if
              do L = nm + 1, nlay
                h2o(icol,L) = h2o(icol,nm)
                c2(icol,L) = co2
                c4(icol,L) = ch4
                n2(icol,L) = n2o
                o22(icol,L) = o2
                o3(icol,L) = o3(icol,nm)
              end do
            end if
            ! ozone : si o3input /= 2 le wrapper ecrase o3 par la climatologie
            ! inirad (o33d vaut 0 a ce stade) ; sinon o33d*amdo.
            if (o3input /= 2) then
              call pinn_inirad(o3mmr, plev(icol,:), 1, nlay - 1)
              do k = 1, nlay
                o3(icol,k) = o3mmr(k) * 0.603461_rb
              end do
            end if
          end do
        end do
        if (allocated(pinn_lw_taug)) deallocate(pinn_lw_taug, pinn_lw_fracs)
        allocate(pinn_lw_taug(ncol, nlay + 1, ngptlw), pinn_lw_fracs(ncol, nlay + 1, ngptlw))
        call cpu_time(t0)
        ok = c_pinn_precompute_lw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                  h2o, o3, c2, c4, n2, o22, pinn_lw_taug, pinn_lw_fracs)
        pinn_lw_ok = (ok /= 0)
        call cpu_time(t1)
        print *, "[PINN] precompute_lw TILE ncol=", ncol, " nlay=", nlay, " cpu=", t1 - t0, " s"
        print *, "[PINN] lw TILE taug min/max:", minval(pinn_lw_taug), maxval(pinn_lw_taug), " fracs min/max:", minval(pinn_lw_fracs), maxval(pinn_lw_fracs)
        ! debug alignement batch <-> per-column : taug des colonnes 1, 100, ncol
        print *, "[PINN] dbg tile col1 feat: play,plev1,plevtop,tlay,tlev,h2o,o3,tsfc =", &
          play(1,1), plev(1,1), plev(1,nlay+1), tlay(1,1), tlev(1,1), h2o(1,1), o3(1,1), tsfc(1)
        print *, "[PINN] dbg tile o3 min/max col1, tlev(nm),tlev(nlay+1) =", &
          minval(o3(1,:)), maxval(o3(1,:)), tlev(1,nm), tlev(1,nlay+1)
        print *, "[PINN] dbg tile col1/100/ncol: taug(k1,ig1) taug(kN,ig1) fracs(1,1) =", &
          pinn_lw_taug(1,1,1), pinn_lw_taug(1,nlay,1), pinn_lw_fracs(1,1,1), &
          pinn_lw_taug(min(100,ncol),1,1), pinn_lw_taug(min(100,ncol),nlay,1), pinn_lw_fracs(min(100,ncol),1,1), &
          pinn_lw_taug(ncol,1,1), pinn_lw_taug(ncol,nlay,1), pinn_lw_fracs(ncol,1,1)
        deallocate(play, plev, tlay, tlev, tsfc, h2o, o3, c2, c4, n2, o22, o3mmr, varint)
      end subroutine pinn_precompute_lw_tile
      subroutine pinn_taumol_lw(nlayers, pavel, wx, coldry, &
                                laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                                colh2o, colco2, colo3, coln2o, colco, colch4, colo2, colbrd, &
                                fac00, fac01, fac10, fac11, &
                                rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                                rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                                rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                                selffac, selffrac, indself, forfac, forfrac, indfor, &
                                minorfrac, scaleminor, scaleminorn2, indminor, &
                                fracs, taug)
        integer(im), intent(in) :: nlayers, laytrop
        real(rb), intent(in) :: pavel(:), wx(:,:), coldry(:)
        integer(im), intent(in) :: jp(:), jt(:), jt1(:), indself(:), indfor(:), indminor(:)
        real(rb), intent(in) :: planklay(:,:), planklev(0:,:), plankbnd(:)
        real(rb), intent(in) :: colh2o(:), colco2(:), colo3(:), coln2o(:), colco(:), colch4(:), colo2(:), colbrd(:)
        real(rb), intent(in) :: fac00(:), fac01(:), fac10(:), fac11(:)
        real(rb), intent(in) :: rat_h2oco2(:), rat_h2oco2_1(:), rat_h2oo3(:), rat_h2oo3_1(:)
        real(rb), intent(in) :: rat_h2on2o(:), rat_h2on2o_1(:), rat_h2och4(:), rat_h2och4_1(:)
        real(rb), intent(in) :: rat_n2oco2(:), rat_n2oco2_1(:), rat_o3co2(:), rat_o3co2_1(:)
        real(rb), intent(in) :: selffac(:), selffrac(:), forfac(:), forfrac(:)
        real(rb), intent(in) :: minorfrac(:), scaleminor(:), scaleminorn2(:)
        real(rb), intent(out) :: fracs(:,:), taug(:,:)
        logical :: use_pinn
        pinn_lw_col = pinn_lw_col + 1
        use_pinn = pinn_lw_on .and. pinn_lw_ok .and. pinn_lw_col <= size(pinn_lw_taug, 1)
        ! mode debug : on fait tourner taumol_ref aussi et on compare sur la meme colonne
        if (pinn_lw_dbg .and. use_pinn) then
          call taumol_ref(nlayers, pavel, wx, coldry, &
                          laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                          colh2o, colco2, colo3, coln2o, colco, colch4, colo2, colbrd, &
                          fac00, fac01, fac10, fac11, &
                          rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                          rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                          rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                          selffac, selffrac, indself, forfac, forfrac, indfor, &
                          minorfrac, scaleminor, scaleminorn2, indminor, &
                          fracs, taug)
          if (.not. allocated(pinn_dbg_taug)) then
            allocate(pinn_dbg_taug(size(taug,1), size(taug,2)), pinn_dbg_fracs(size(fracs,1), size(fracs,2)))
          end if
          pinn_dbg_taug = taug
          pinn_dbg_fracs = fracs
        end if
        if (use_pinn) then
          fracs(1:nlayers+1, 1:ngptlw) = pinn_lw_fracs(pinn_lw_col, 1:nlayers+1, 1:ngptlw)
          taug(1:nlayers+1, 1:ngptlw)  = pinn_lw_taug(pinn_lw_col, 1:nlayers+1, 1:ngptlw)
          if (pinn_lw_col == 1 .or. pinn_lw_col == 100 .or. pinn_lw_col == size(pinn_lw_taug, 1)) then
            print *, "[PINN] dbg per-col", pinn_lw_col, "taug(k1,ig1)=", taug(1,1), " taug(kN,ig1)=", taug(nlayers+1,1), " fracs(1,1)=", fracs(1,1)
            if (pinn_lw_dbg) then
              print *, "[PINN] CMP col", pinn_lw_col, " max|dtaug|=", maxval(abs(taug - pinn_dbg_taug)), &
                " max|dfracs|=", maxval(abs(fracs - pinn_dbg_fracs))
              print *, "[PINN] CMP col", pinn_lw_col, " ref taug(k1,kN,ig1)=", pinn_dbg_taug(1,1), pinn_dbg_taug(nlayers+1,1), &
                " pinn=", taug(1,1), taug(nlayers+1,1), " ref fracs(1,1)=", pinn_dbg_fracs(1,1), " pinn=", fracs(1,1)
            end if
          end if
        else
          call taumol_ref(nlayers, pavel, wx, coldry, &
                          laytrop, jp, jt, jt1, planklay, planklev, plankbnd, &
                          colh2o, colco2, colo3, coln2o, colco, colch4, colo2, colbrd, &
                          fac00, fac01, fac10, fac11, &
                          rat_h2oco2, rat_h2oco2_1, rat_h2oo3, rat_h2oo3_1, &
                          rat_h2on2o, rat_h2on2o_1, rat_h2och4, rat_h2och4_1, &
                          rat_n2oco2, rat_n2oco2_1, rat_o3co2, rat_o3co2_1, &
                          selffac, selffrac, indself, forfac, forfrac, indfor, &
                          minorfrac, scaleminor, scaleminorn2, indminor, &
                          fracs, taug)
        end if
      end subroutine pinn_taumol_lw
      end module module_pinn_shell_lw
