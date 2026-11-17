      module module_pinn_shell_sw
! Shell de taumol_sw pour WRF (insere dans module_ra_rrtmg_sw.F par patch_wrf.sh,
! avant module rrtmg_sw_spcvmc). spcvmc_sw appelle taumol_sw en interne par colonne :
! ici on appelle taumol_sw_ref (sfluxzen + fallback) puis on ecrase taug/taur par
! les valeurs PINN precalculees en batch (pinn_precompute_sw, insere avant la boucle
! iplon de rrtmg_sw) si la variable denv PINN_MODEL est definie.
! NOTE: pas de use iso_c_binding ici (le pipeline cpp de WRF + gfortran 4.8 fait
! echouer c_char) et pas de double-slash (le cpp en mode C le prend pour un commentaire) :
! on declare les types C a la main (character(len=1)=c_char, real(4)=c_float,
! integer par defaut = c_int) et on construit la chaine NUL a la main.
      use parkind, only: im => kind_im, rb => kind_rb
      use parrrsw, only: mxlay, ngptsw
      use rrtmg_sw_taumol, only: taumol_sw_ref
      implicit none
      logical :: pinn_sw_on = .false.
      logical :: pinn_sw_ok = .false.
      logical :: pinn_sw_init_done = .false.
      integer(im) :: pinn_sw_col = 0
      real(4), allocatable :: pinn_sw_taug(:, :, :), pinn_sw_taur(:, :, :)  ! (ncol, nlay, ngptsw)
      interface
        function c_pinn_init(m) result(ok) bind(C, name="pinn_torch_init")
          integer :: ok
          character(len=1), intent(in) :: m(*)
        end function c_pinn_init
        function c_pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                     h2o, o3, co2, ch4, n2o, o2, taug, taur) &
             result(ok) bind(C, name="pinn_torch_precompute_sw")
          integer :: ok
          integer, value, intent(in) :: ncol, nlay
          real(4), intent(in) :: play(*), plev(*), tlay(*), tlev(*), tsfc(*)
          real(4), intent(in) :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
          real(4), intent(out) :: taug(*), taur(*)
        end function c_pinn_precompute_sw
      end interface
      contains
      subroutine pinn_sw_init_once()
        character(len=1024) :: m
        character(len=1025) :: mc
        character(len=64) :: fl
        integer :: ios, ios2, fv, l, ok
        if (pinn_sw_init_done) return
        pinn_sw_init_done = .true.
        call get_environment_variable("PINN_MODEL", m, status=ios)
        if (ios /= 0 .or. len_trim(m) == 0) return
        if (trim(m) == "off" .or. trim(m) == "none" .or. trim(m) == "fortran") return
        fv = 1
        call get_environment_variable("PINN_SW", fl, status=ios2)
        if (ios2 == 0 .and. len_trim(fl) > 0) read(fl, *, iostat=ios2) fv
        if (fv == 0) then
          print *, "[PINN] SW desactive (PINN_SW=0), Fortran taumol_sw"
          return
        end if
        l = len_trim(m)
        mc = achar(0)
        mc(1:l) = m(1:l)
        ok = c_pinn_init(mc)
        if (ok == 0) then
          print *, "[PINN] SW: echec chargement modele -> Fortran taumol_sw_ref"
          return
        end if
        pinn_sw_on = .true.
        print *, "[PINN] SW: modele charge: ", trim(m)
      end subroutine pinn_sw_init_once
      subroutine pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                    h2o, o3, co2, ch4, n2o, o2)
        integer(im), intent(in) :: ncol, nlay
        real(rb), intent(in) :: play(:,:), plev(:,:), tlay(:,:), tlev(:,:), tsfc(:)
        real(rb), intent(in) :: h2o(:,:), o3(:,:), co2(:,:), ch4(:,:), n2o(:,:), o2(:,:)
        real :: t0, t1
        integer :: ok
        call pinn_sw_init_once()
        pinn_sw_col = 0
        if (.not. pinn_sw_on) return
        if (allocated(pinn_sw_taug)) deallocate(pinn_sw_taug, pinn_sw_taur)
        allocate(pinn_sw_taug(ncol, nlay, ngptsw), pinn_sw_taur(ncol, nlay, ngptsw))
        call cpu_time(t0)
        ok = c_pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                  h2o, o3, co2, ch4, n2o, o2, pinn_sw_taug, pinn_sw_taur)
        pinn_sw_ok = (ok /= 0)
        call cpu_time(t1)
        print *, "[PINN] precompute_sw ncol=", ncol, " nlay=", nlay, " cpu=", t1 - t0, " s"
      end subroutine pinn_precompute_sw
      subroutine pinn_reset_sw()
        pinn_sw_col = 0
      end subroutine pinn_reset_sw
      subroutine taumol_sw(nlayers, colh2o, colco2, colch4, colo2, colo3, colmol, &
                           laytrop, jp, jt, jt1, fac00, fac01, fac10, fac11, &
                           selffac, selffrac, indself, forfac, forfrac, indfor, &
                           sfluxzen, taug, taur)
        integer(im), intent(in) :: nlayers, laytrop
        real(rb), intent(in) :: colh2o(:), colco2(:), colch4(:), colo2(:), colo3(:), colmol(:)
        integer(im), intent(in) :: jp(:), jt(:), jt1(:), indself(:), indfor(:)
        real(rb), intent(in) :: fac00(:), fac01(:), fac10(:), fac11(:)
        real(rb), intent(in) :: selffac(:), selffrac(:), forfac(:), forfrac(:)
        real(rb), intent(out) :: sfluxzen(:), taug(:,:), taur(:,:)
        pinn_sw_col = pinn_sw_col + 1
        call taumol_sw_ref(nlayers, colh2o, colco2, colch4, colo2, colo3, colmol, &
                           laytrop, jp, jt, jt1, fac00, fac01, fac10, fac11, &
                           selffac, selffrac, indself, forfac, forfrac, indfor, &
                           sfluxzen, taug, taur)
        if (pinn_sw_on .and. pinn_sw_ok .and. pinn_sw_col <= size(pinn_sw_taug, 1)) then
          taug(1:nlayers, 1:ngptsw) = pinn_sw_taug(pinn_sw_col, 1:nlayers, 1:ngptsw)
          taur(1:nlayers, 1:ngptsw) = pinn_sw_taur(pinn_sw_col, 1:nlayers, 1:ngptsw)
        end if
      end subroutine taumol_sw
      end module module_pinn_shell_sw
