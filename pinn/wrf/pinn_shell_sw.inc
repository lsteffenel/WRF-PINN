      module module_pinn_shell_sw
! Shell de taumol_sw pour WRF (insere dans module_ra_rrtmg_sw.F par patch_wrf.sh,
! avant module rrtmg_sw_spcvmc). spcvmc_sw appelle taumol_sw en interne par colonne :
! ici on appelle taumol_sw_ref (sfluxzen + fallback) puis on ecrase taug/taur par
! les valeurs PINN precalculees en batch (pinn_precompute_sw, insere avant la boucle
! iplon de rrtmg_sw) si la variable d'env PINN_MODEL est definie.
      use iso_c_binding
      use parkind, only: im => kind_im, rb => kind_rb
      use parrrsw, only: mxlay, ngptsw
      use rrtmg_sw_taumol, only: taumol_sw_ref
      implicit none
      logical :: pinn_sw_on = .false.
      logical :: pinn_sw_init_done = .false.
      integer(im) :: pinn_sw_col = 0
      real(c_float), allocatable :: pinn_sw_taug(:, :, :), pinn_sw_taur(:, :, :)  ! (ncol, nlay, ngptsw)
      interface
        subroutine c_pinn_init(m) bind(C, name="pinn_torch_init")
          character(kind=c_char), intent(in) :: m(*)
        end subroutine c_pinn_init
        subroutine c_pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                        h2o, o3, co2, ch4, n2o, o2, taug, taur) &
             bind(C, name="pinn_torch_precompute_sw")
          import
          integer(c_int), value, intent(in) :: ncol, nlay
          real(c_float), intent(in) :: play(*), plev(*), tlay(*), tlev(*), tsfc(*)
          real(c_float), intent(in) :: h2o(*), o3(*), co2(*), ch4(*), n2o(*), o2(*)
          real(c_float), intent(out) :: taug(*), taur(*)
        end subroutine c_pinn_precompute_sw
      end interface
      contains
      subroutine pinn_sw_init_once()
        character(len=1024) :: m
        integer :: ios
        if (pinn_sw_init_done) return
        pinn_sw_init_done = .true.
        call get_environment_variable("PINN_MODEL", m, status=ios)
        if (ios == 0 .and. len_trim(m) > 0) then
          call c_pinn_init(trim(m)//c_null_char)
          pinn_sw_on = .true.
          print *, "[PINN] SW: modele charge: ", trim(m)
        end if
      end subroutine pinn_sw_init_once
      subroutine pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                    h2o, o3, co2, ch4, n2o, o2)
        integer(im), intent(in) :: ncol, nlay
        real(rb), intent(in) :: play(:,:), plev(:,:), tlay(:,:), tlev(:,:), tsfc(:)
        real(rb), intent(in) :: h2o(:,:), o3(:,:), co2(:,:), ch4(:,:), n2o(:,:), o2(:,:)
        call pinn_sw_init_once()
        pinn_sw_col = 0
        if (.not. pinn_sw_on) return
        if (allocated(pinn_sw_taug)) deallocate(pinn_sw_taug, pinn_sw_taur)
        allocate(pinn_sw_taug(ncol, nlay, ngptsw), pinn_sw_taur(ncol, nlay, ngptsw))
        call c_pinn_precompute_sw(ncol, nlay, play, plev, tlay, tlev, tsfc, &
                                  h2o, o3, co2, ch4, n2o, o2, pinn_sw_taug, pinn_sw_taur)
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
        if (pinn_sw_on .and. pinn_sw_col <= size(pinn_sw_taug, 1)) then
          taug(1:nlayers, 1:ngptsw) = pinn_sw_taug(pinn_sw_col, 1:nlayers, 1:ngptsw)
          taur(1:nlayers, 1:ngptsw) = pinn_sw_taur(pinn_sw_col, 1:nlayers, 1:ngptsw)
        end if
      end subroutine taumol_sw
      end module module_pinn_shell_sw
