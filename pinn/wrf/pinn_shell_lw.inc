      module module_pinn_shell_lw
! Shell de taumol (RRTMG LW) pour WRF (insere dans module_ra_rrtmg_lw.F par
! patch_wrf.sh, juste avant module rrtmg_lw_rad). Le driver appelle taumol par
! colonne : on remplace ce call par pinn_taumol_lw (sed), qui copie fracs/taug
! depuis les buffers PINN precalcules en batch (pinn_precompute_lw, insere avant
! la boucle iplon) si PINN_MODEL est defini, sinon appelle taumol_ref.
! NOTE: pas de use iso_c_binding ici (le pipeline cpp de WRF + gfortran 4.8 fait
! echouer c_char) et pas de double-slash (le cpp en mode C le prend pour un commentaire) :
! on declare les types C a la main (character(len=1)=c_char, real(4)=c_float,
! integer par defaut = c_int) et on construit la chaine NUL a la main.
      use parkind, only: im => kind_im, rb => kind_rb
      use parrrtm, only: mxlay, ngptlw
      use rrtmg_lw_taumol, only: taumol_ref
      implicit none
      logical :: pinn_lw_on = .false.
      logical :: pinn_lw_ok = .false.
      logical :: pinn_lw_init_done = .false.
      integer(im) :: pinn_lw_col = 0
      real(4), allocatable :: pinn_lw_taug(:, :, :), pinn_lw_fracs(:, :, :)  ! (ncol, mxlay+1, ngptlw)
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
! ncol=1 : le batch na de sens quau niveau du wrapper RRTMG_LWRAD, avant sa
! boucle j). Meme reconstruction des profils 2D que pinn_precompute_sw_tile.
      subroutine pinn_precompute_lw_tile(its, ite, jts, jte, kts, kte, nlayers, &
                                         p3d, p8w, t3d, t8w, qv3d, o33d, tsk, yr)
        integer(im), intent(in) :: its, ite, jts, jte, kts, kte, nlayers, yr
        real(rb), intent(in) :: p3d(:,:,:), p8w(:,:,:), t3d(:,:,:), t8w(:,:,:)
        real(rb), intent(in) :: qv3d(:,:,:), o33d(:,:,:), tsk(:,:)
        integer(im) :: nx, ny, ncol, nlay, nm, i, j, k, kk, L, icol, ok
        real(rb) :: co2, ch4, n2o, o2, t0, t1
        real(rb), allocatable :: play(:,:), plev(:,:), tlay(:,:), tlev(:,:), tsfc(:)
        real(rb), allocatable :: h2o(:,:), o3(:,:), c2(:,:), c4(:,:), n2(:,:), o22(:,:)
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
            if (nlay >= nm + 1) then
            play(icol,nm+1) = 0.5_rb * plev(icol,nm+1)
            tlay(icol,nm+1) = tlev(icol,nm+1)
            plev(icol,nm+2) = 1.0e-5_rb
            tlev(icol,nm+2) = tlev(icol,nm+1)
            h2o(icol,nm+1) = h2o(icol,nm)
            o3(icol,nm+1) = o3(icol,nm)
            c2(icol,nm+1) = co2
            c4(icol,nm+1) = ch4
            n2(icol,nm+1) = n2o
            o22(icol,nm+1) = o2
            do L = nm + 2, nlay
              plev(icol,L+1) = plev(icol,L) - 4._rb
              play(icol,L) = 0.5_rb * (plev(icol,L) + plev(icol,L+1))
              tlay(icol,L) = tlev(icol,L)
              tlev(icol,L+1) = tlev(icol,L)
              h2o(icol,L) = h2o(icol,nm)
              o3(icol,L) = o3(icol,nm)
              c2(icol,L) = co2
              c4(icol,L) = ch4
              n2(icol,L) = n2o
              o22(icol,L) = o2
            end do
            plev(icol,nlay+1) = 0.0_rb
            play(icol,nlay) = 0.5_rb * (plev(icol,nlay) + plev(icol,nlay+1))
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
        deallocate(play, plev, tlay, tlev, tsfc, h2o, o3, c2, c4, n2, o22)
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
        pinn_lw_col = pinn_lw_col + 1
        if (pinn_lw_on .and. pinn_lw_ok .and. pinn_lw_col <= size(pinn_lw_taug, 1)) then
          fracs(1:nlayers+1, 1:ngptlw) = pinn_lw_fracs(pinn_lw_col, 1:nlayers+1, 1:ngptlw)
          taug(1:nlayers+1, 1:ngptlw)  = pinn_lw_taug(pinn_lw_col, 1:nlayers+1, 1:ngptlw)
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
