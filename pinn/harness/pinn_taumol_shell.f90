! Shell de remplacement de taumol_sw dans librrtmg_rad_pinn.so.
! Dans le core RRTMG, spcvmc_sw appelle taumol_sw EN INTERNE (rrtmg_sw_core.F) :
! build_rad.sh renomme la definition en taumol_sw_ref et fait `use
! pinn_taumol_shell, only: taumol_sw` dans les modules utilisateurs, de sorte que
! spcvmc_sw recoive ici les taug/taur fournis depuis Python (modele PINN).
! sfluxzen (fonction source solaire par g-point) est aussi fourni : il ne depend
! pas du profil (sfluxref des tables), Python le recupere une fois via
! pinn_sw_sfluxzen du .so de reference.
! Compile AVANT rrtmg_sw_core.F (sinon cercle de modules) : on hardcode donc
! mxlay/ngptsw de parrrsw (203/112, fixes dans WRF 4.6.1).
module pinn_taumol_shell
  use iso_c_binding
  use parkind, only: im => kind_im, rb => kind_rb
  implicit none
  integer, parameter :: S_MXLAY = 203, S_NGPTSW = 112
  real(c_float), bind(C) :: pinn_sfluxzen_ext(S_NGPTSW)
  real(c_float), bind(C) :: pinn_taug_ext(S_MXLAY*S_NGPTSW)
  real(c_float), bind(C) :: pinn_taur_ext(S_MXLAY*S_NGPTSW)
contains
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
    integer(im) :: ig, lay
    do ig = 1, S_NGPTSW
      sfluxzen(ig) = pinn_sfluxzen_ext(ig)
    end do
    taug = 0._rb
    taur = 0._rb
    do ig = 1, min(S_NGPTSW, size(taug, 2))
      do lay = 1, nlayers
        taug(lay, ig) = pinn_taug_ext(lay + (ig-1)*S_MXLAY)
        taur(lay, ig) = pinn_taur_ext(lay + (ig-1)*S_MXLAY)
      end do
    end do
  end subroutine taumol_sw
end module pinn_taumol_shell
